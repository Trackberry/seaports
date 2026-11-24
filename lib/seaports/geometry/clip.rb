# frozen_string_literal: true

require "json"

require_relative "osm"
require_relative "planar"

module Seaports
  module Geometry
    # Cuts derived port limits down to where a ship can be: the water
    # OpenStreetMap maps inside them, plus the port's terminals (and the
    # basins its selection lists) kept whole.
    #
    # A convex hull over a port's terminals takes in whatever lies between
    # them: the town on the hill behind Lyttelton, Mount Maunganui between
    # Tauranga's two wharves, Petit-Couronne between Rouen's quays. No ship is
    # ever there, so the land only makes the drawing wrong. Cutting it away
    # keeps every answer a tracker needs (a ship at a berth, in a dock, in
    # the river between quays) and drops the towns.
    #
    #   limits = hull ∩ (sea ∪ mapped water ∪ terminals
    #                    ∪ (terminals grown by KEEP_MARGIN_M ∩ water grown by KEEP_MARGIN_M))
    #
    # The sea comes from OpenStreetMap's coastline, drawn with the land on its
    # left: the coastline and the edge of the box around the hull cut the box
    # into faces, and each face is sea or land by which side of the coastline
    # beside it most of that coastline says it is on. Only the parts that
    # touch a terminal or a listed basin are kept, so a pond in a park is not
    # a port; holes under MIN_HOLE_M2 (a pontoon, an islet) are filled, and
    # the outline is simplified to within SIMPLIFY_M.
    #
    # Build time only, and the one place the gem uses a geometry library:
    # GEOS, through the rgeo gem's C extension, does the overlay, which a
    # hand-rolled clipper of concave polygons with holes would get wrong at
    # the edges. The outlines it builds are shipped as plain GeoJSON, so
    # nothing that reads them needs it. Coordinates are projected to metres on
    # a plane tangent at the hull's centre for the work, and rounded back to
    # six decimals, like every other shape in the files.
    class Clip
      # A terminal (or a kept area) and the water (with the listed basins)
      # are each grown by this much and the two overlaps kept, so that a
      # terminal drawn a few metres back from the water OpenStreetMap maps
      # still meets it. The margin bridges only between the two: land is
      # taken only where it lies within the margin of both. That is the gap
      # to the water, about the margin of shore either side of a terminal's
      # ends, and, behind a terminal narrower than the margin, the strip
      # still within the margin of the water. Behind a deeper terminal's fence
      # the houses stay outside.
      KEEP_MARGIN_M = 30
      SIMPLIFY_M = 8
      # Simplifying and rounding to six decimals can nick a terminal the
      # limits run right along: it is put back, padded by this much.
      PAD_M = 1
      MIN_HOLE_M2 = 10_000
      # The box around the hull the coastline is cut to, a little wider than
      # the hull so its faces reach past every edge of it.
      BOX_MARGIN_M = 200
      # Water is fetched for a box wider still, so no coastline way that
      # crosses the cutting box is missed: an extract keeps only the ways
      # with a node inside the box it is cut to.
      FETCH_MARGIN_M = 1_000

      # [west, south, east, north] to fetch the water for +hull+ in.
      def self.fetch_bbox(hull)
        west, south, east, north = Planar.bbox(hull)
        dlat = FETCH_MARGIN_M / Planar::M_PER_DEGREE
        dlng = dlat / Math.cos(((south + north) / 2.0) * Math::PI / 180.0)
        [west - dlng, south - dlat, east + dlng, north + dlat].map { |value| value.round(6) }
      end

      # The GEOS library's version, for the build log: GEOS releases can
      # simplify the same shape a vertex differently.
      def self.geos_version
        load_geos!
        RGeo::Geos.version
      end

      class Unavailable < StandardError; end
      # A cut that cannot be made: nothing left, or an invalid result.
      class Failed < StandardError; end

      # rgeo installs without GEOS when the library is not there at install
      # time, and only fails later, on the first geometry it is asked for:
      # ask at the start instead.
      def self.load_geos!
        require "rgeo"
        return if RGeo::Geos.capi_supported?

        raise Unavailable, "clip: water needs GEOS at build time, and the rgeo gem was installed without it: " \
                           "brew install geos (or apt-get install libgeos-dev), then gem pristine rgeo"
      rescue LoadError => e
        raise Unavailable, "clip: water needs GEOS at build time: brew install geos (or apt-get install libgeos-dev) " \
                           "and bundle install, for the rgeo gem (#{e.message})"
      end

      # A terminal "touches water" when water inside the hull lies within its
      # margin, which is also when the two join into one part of the limits.
      TOUCH_M = KEEP_MARGIN_M

      # +hull+ is the derived limits, a GeoJSON Polygon; +terminals+ a Hash
      # of each terminal's name to its geometry, and +basins+ the other areas
      # the selection lists, all kept whole; +water+ what Water.overpass
      # answers.
      def initialize(hull:, terminals:, water:, basins: [])
        self.class.load_geos!
        @hull = hull
        @terminals = terminals.select { |_, geometry| area?(geometry) }
        @basins = basins.select { |geometry| area?(geometry) }
        @water = water
        lng0, lat0 = Planar.label_point(hull) || Planar.positions(hull).first
        @origin = [lng0, lat0]
        @scale_x = Planar::M_PER_DEGREE * Math.cos(lat0 * Math::PI / 180.0)
        @factory = RGeo::Geos.factory(native_interface: :capi, buffer_resolution: 4)
      end

      # The clipped limits, a GeoJSON Polygon or MultiPolygon.
      def geometry
        @geometry ||= begin
          kept_areas = union((@terminals.values + @basins).map { |geometry| geos(geometry).make_valid })
          # Listed basins count as water for a terminal, but not for
          # themselves, or the margin would come back all round them.
          terminal_areas = union(@terminals.values.map { |geometry| geos(geometry).make_valid })
          basin_areas = union(@basins.map { |geometry| geos(geometry).make_valid })
          bridge = union([terminal_areas.buffer(KEEP_MARGIN_M).intersection(waterish.buffer(KEEP_MARGIN_M)),
                          basin_areas.buffer(KEEP_MARGIN_M).intersection(water_inside.buffer(KEEP_MARGIN_M))])
          cut = hull.intersection(union([water_inside, kept_areas, bridge]))
          parts = polygons(cut).select { |polygon| polygon.intersects?(kept_areas) }.map { |polygon| fill_holes(polygon) }
          raise Failed, "nothing of the hull is left after the cut" if parts.empty?

          # Padded lightly simplified, so the pad adds no unsimplified arcs.
          pad = kept_areas.buffer(PAD_M).simplify_preserve_topology(PAD_M / 2.0).intersection(hull)
          simplified(union(parts), pad)
        end
      end

      # The names of the terminals with no water within TOUCH_M of them inside
      # the hull: a ship alongside one would be outside the limits. Usually a
      # river or a dock OpenStreetMap maps only as a line, or not at all. A
      # basin the selection lists counts as water: it is listed because it
      # is the port's and OpenStreetMap does not tag it as water.
      def dry_terminals
        @terminals.reject { |_, geometry| geos(geometry).make_valid.buffer(TOUCH_M).intersects?(waterish) }.keys
      end

      # +limits+ less +areas+ (GeoJSON areas the selection excludes: a marina,
      # a housing estate by the water), as [geometry, conflicts]. +keep+ is a
      # Hash of name to geometry that must not lose any of itself to the cut,
      # the terminals and anchorages; their names come back as conflicts, and
      # the geometry as nil, when any would.
      def self.subtract(limits, areas, keep: {})
        new(hull: limits, terminals: {}, water: { "coastline" => [], "areas" => [] }).subtract(areas, keep)
      end

      def subtract(areas, keep)
        # Outer rings only: a block's courtyard would otherwise stay behind
        # as a speck of limits on its own.
        cut = union(areas.flat_map { |geometry| polygons(geos(geometry).make_valid).map { |polygon| @factory.polygon(polygon.exterior_ring) } })
        conflicts = keep.select { |_, geometry| polygons(geos(geometry).make_valid.intersection(cut)).sum(&:area) > 1 }.keys
        return [nil, conflicts] unless conflicts.empty?

        parts = polygons(hull.difference(cut))
        raise Failed, "nothing of the limits is left after the exclusions" if parts.empty?

        result = to_geojson(union(parts))
        raise Failed, "the limits less the exclusions are not a valid polygon once rounded" unless geos_lnglat(result).valid?

        [result, []]
      end

      private

      # The water inside the hull, and the basins the selection lists.
      def waterish
        @waterish ||= union([water_inside] + @basins.map { |geometry| geos(geometry).make_valid })
      end

      def area?(geometry) = %w[Polygon MultiPolygon].include?(geometry && geometry["type"])

      def hull
        @hull_geos ||= geos(@hull).tap { |shape| raise Failed, "the hull is not a valid polygon" unless shape.valid? }
      end

      def water_inside
        @water_inside ||= water(hull).intersection(hull)
      end

      def simplified(merged, kept)
        [SIMPLIFY_M, SIMPLIFY_M / 2.0, 0].each do |tolerance|
          # rgeo raises on invalid input rather than returning it: an invalid
          # result at one tolerance means trying a smaller one.
          begin
            shape = tolerance.positive? ? merged.simplify_preserve_topology(tolerance) : merged
            next unless shape.valid?

            result = to_geojson(union([shape, kept]))
            return result if geos_lnglat(result).valid?
          rescue RGeo::Error::InvalidGeometry
            next
          end
        end
        raise Failed, "the clipped limits are not a valid polygon once rounded"
      end

      # The sea inside the box around +hull+, and every water area there.
      def water(hull)
        west, south, east, north = bounds(hull.envelope)
        box = box(west - BOX_MARGIN_M, south - BOX_MARGIN_M, east + BOX_MARGIN_M, north + BOX_MARGIN_M)
        areas = Array(@water["areas"]).filter_map do |geometry|
          shape = geos(geometry).make_valid
          shape.intersects?(box) ? shape : nil
        end
        union(areas + [sea(box)].compact).intersection(box)
      end

      def sea(box)
        lines = Array(@water["coastline"]).select { |line| line.uniq.size >= 2 }.map { |line| line.map { |position| local(position) } }
        shapes = lines.map { |positions| line(positions) }
        inside = shapes.each_index.select { |i| shapes[i].intersects?(box) }
        return nil if inside.empty?

        linework = @factory.multi_line_string(inside.map { |i| shapes[i] }).intersection(box).union(box.boundary)
        faces = children(linework.polygonize).map { |face| [face, bounds(face)] }
        faces.each { |face, _| face.prepare! }
        votes = Hash.new { |hash, index| hash[index] = [0, 0] }
        box.prepare!
        inside.each do |i|
          lines[i].each_cons(2) do |(x1, y1), (x2, y2)|
            length = Math.hypot(x2 - x1, y2 - y1)
            next if length.zero?

            # The middle of the part of the segment inside the box: a long
            # two-node mole or beach can cross the box with its own middle
            # far outside, and still splits the box into faces.
            mx = (x1 + x2) / 2.0
            my = (y1 + y2) / 2.0
            unless box.contains?(@factory.point(mx, my))
              piece = line([[x1, y1], [x2, y2]]).intersection(box)
              next if piece.empty? || piece.geometry_type.type_name != "LineString"

              mx = (piece.start_point.x + piece.end_point.x) / 2.0
              my = (piece.start_point.y + piece.end_point.y) / 2.0
            end

            # Half a metre to the right of the coastline is sea, to the left land.
            nx = (y2 - y1) / length * 0.5
            ny = -(x2 - x1) / length * 0.5
            [[mx + nx, my + ny, 0], [mx - nx, my - ny, 1]].each do |x, y, side|
              index = faces.index { |face, (minx, miny, maxx, maxy)| x.between?(minx, maxx) && y.between?(miny, maxy) && face.contains?(@factory.point(x, y)) }
              votes[index][side] += 1 if index
            end
          end
        end
        seas = votes.select { |_, (sea, land)| sea > land }.keys.sort.map { |index| faces[index].first }
        seas.empty? ? nil : union(seas)
      end

      def box(x1, y1, x2, y2) = @factory.polygon(ring([[x1, y1], [x2, y1], [x2, y2], [x1, y2], [x1, y1]]))

      def ring(positions) = @factory.linear_ring(positions.map { |x, y| @factory.point(x, y) })

      def line(positions) = @factory.line_string(positions.map { |x, y| @factory.point(x, y) })

      # [west, south, east, north] of a polygon's outer ring.
      def bounds(polygon)
        xs, ys = polygon.exterior_ring.points.map { |point| [point.x, point.y] }.transpose
        [xs.min, ys.min, xs.max, ys.max]
      end

      def union(geometries) = @factory.collection(geometries.compact).unary_union

      # The parts of a collection; a lone geometry is its own part.
      def children(geometry)
        return [geometry] unless geometry.respond_to?(:num_geometries)

        Array.new(geometry.num_geometries) { |i| geometry.geometry_n(i) }
      end

      def polygons(geometry)
        case geometry.geometry_type.type_name
        when "Polygon" then [geometry]
        when "MultiPolygon", "GeometryCollection" then children(geometry).flat_map { |part| polygons(part) }
        else []
        end
      end

      def fill_holes(polygon)
        kept = polygon.interior_rings.select { |hole| @factory.polygon(hole).area >= MIN_HOLE_M2 }
        @factory.polygon(polygon.exterior_ring, kept)
      end

      def local((lng, lat)) = [(lng - @origin[0]) * @scale_x, (lat - @origin[1]) * Planar::M_PER_DEGREE]

      def lnglat((x, y)) = [(@origin[0] + (x / @scale_x)).round(6), (@origin[1] + (y / Planar::M_PER_DEGREE)).round(6)]

      def geos(geometry)
        read(Planar.polygons(geometry).map { |rings| rings.map { |positions| positions.map { |position| local(position) } } })
      end

      def geos_lnglat(geometry) = read(Planar.polygons(geometry))

      # A MultiPolygon from [[ring, ...], ...] positions, through WKT, which
      # GEOS reads as it is given.
      def read(polygons)
        raise Failed, "a shape with no polygon in it cannot be clipped" if polygons.empty?

        text = polygons.map { |rings| "(#{rings.map { |positions| "(#{positions.map { |x, y| "#{x} #{y}" }.join(', ')})" }.join(', ')})" }
        @factory.parse_wkt("MULTIPOLYGON (#{text.join(', ')})")
      end

      # Largest part first; outer rings counter-clockwise and holes
      # clockwise, as Osm writes them.
      def to_geojson(geometry)
        parts = polygons(geometry).sort_by { |polygon| -polygon.area }.map do |polygon|
          rings = [polygon.exterior_ring] + polygon.interior_rings
          rings.each_with_index.map do |ring, i|
            positions = ring.points.map { |vertex| lnglat([vertex.x, vertex.y]) }.chunk_while { |a, b| a == b }.map(&:first)
            Osm.orient(positions, outer: i.zero?)
          end
        end
        # A part whose outer ring collapses is dropped with its holes, not
        # left as a polygon whose first hole has become its outline.
        parts = parts.select { |rings| rings.first.size >= 4 }.map { |rings| rings.select { |ring| ring.size >= 4 } }
        parts.size == 1 ? { "type" => "Polygon", "coordinates" => parts.first } : { "type" => "MultiPolygon", "coordinates" => parts }
      end
    end
  end
end
