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
    #   limits = hull ∩ (sea ∪ mapped water ∪ terminals grown by KEEP_MARGIN_M)
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
    # GEOS, through the ffi-geos gem, does the overlay, which a hand-rolled
    # clipper of concave polygons with holes would get wrong at the edges.
    # The outlines it builds are shipped as plain GeoJSON, so nothing that
    # reads them needs it. Coordinates are projected to metres on a plane
    # tangent at the hull's centre for the work, and rounded back to six
    # decimals, like every other shape in the files.
    class Clip
      # A terminal is grown by this much before the cut, so that one drawn a
      # few metres back from the water OpenStreetMap maps still meets it,
      # and so that simplifying never nicks it.
      KEEP_MARGIN_M = 30
      SIMPLIFY_M = 8
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
        Geos.version
      end

      class Unavailable < StandardError; end
      # A cut that cannot be made: nothing left, or an invalid result.
      class Failed < StandardError; end

      def self.load_geos!
        require "ffi-geos"
      rescue LoadError => e
        raise Unavailable, "clip: water needs GEOS at build time: brew install geos (or apt-get install libgeos-dev) " \
                           "and bundle install, for the ffi-geos gem (#{e.message})"
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
      end

      # The clipped limits, a GeoJSON Polygon or MultiPolygon.
      def geometry
        @geometry ||= begin
          kept_areas = union((@terminals.values + @basins).map { |geometry| geos(geometry).make_valid })
          cut = hull.intersection(union([water_inside, kept_areas.buffer(KEEP_MARGIN_M, quad_segs: 4)]))
          parts = polygons(cut).select { |polygon| polygon.intersects?(kept_areas) }.map { |polygon| fill_holes(polygon) }
          raise Failed, "nothing of the hull is left after the cut" if parts.empty?

          simplified(union(parts))
        end
      end

      # The names of the terminals with no water within TOUCH_M of them inside
      # the hull: a ship alongside one would be outside the limits. Usually a
      # river or a dock OpenStreetMap maps only as a line, or not at all. A
      # basin the selection lists counts as water: it is listed because it
      # is the port's and OpenStreetMap does not tag it as water.
      def dry_terminals
        water = union([water_inside] + @basins.map { |geometry| geos(geometry).make_valid })
        @terminals.reject { |_, geometry| geos(geometry).make_valid.buffer(TOUCH_M, quad_segs: 4).intersects?(water) }.keys
      end

      private

      def area?(geometry) = %w[Polygon MultiPolygon].include?(geometry && geometry["type"])

      def hull
        @hull_geos ||= geos(@hull).tap { |shape| raise Failed, "the hull is not a valid polygon" unless shape.valid? }
      end

      def water_inside
        @water_inside ||= water(hull).intersection(hull)
      end

      def simplified(merged)
        [SIMPLIFY_M, SIMPLIFY_M / 2.0, 0].each do |tolerance|
          shape = tolerance.positive? ? merged.topology_preserve_simplify(tolerance) : merged
          result = to_geojson(shape)
          return result if geos_lnglat(result).valid?
        end
        raise Failed, "the clipped limits are not a valid polygon once rounded"
      end

      # The sea inside the box around +hull+, and every water area there.
      def water(hull)
        box = hull.envelope.buffer(BOX_MARGIN_M, quad_segs: 1).envelope
        areas = Array(@water["areas"]).filter_map do |geometry|
          shape = geos(geometry).make_valid
          shape.intersects?(box) ? shape : nil
        end
        union(areas + [sea(box)].compact).intersection(box)
      end

      def sea(box)
        lines = Array(@water["coastline"]).select { |line| line.uniq.size >= 2 }.map { |line| line.map { |position| local(position) } }
        shapes = lines.map { |line| Geos.create_line_string(line) }
        inside = shapes.each_index.select { |i| shapes[i].intersects?(box) }
        return nil if inside.empty?

        linework = Geos.create_multi_line_string(inside.map { |i| shapes[i].clone }).intersection(box).union(box.boundary)
        faces = linework.polygonize.map { |face| [face, face.to_prepared, envelope(face)] }
        votes = Hash.new { |hash, index| hash[index] = [0, 0] }
        prepared_box = box.to_prepared
        inside.each do |i|
          lines[i].each_cons(2) do |(x1, y1), (x2, y2)|
            length = Math.hypot(x2 - x1, y2 - y1)
            next if length.zero?

            # The middle of the part of the segment inside the box: a long
            # two-node mole or beach can cross the box with its own middle
            # far outside, and still splits the box into faces.
            mx = (x1 + x2) / 2.0
            my = (y1 + y2) / 2.0
            unless prepared_box.contains?(Geos.create_point(mx, my))
              piece = Geos.create_line_string([[x1, y1], [x2, y2]]).intersection(box)
              next if piece.empty? || !piece.is_a?(Geos::LineString)

              (ax, ay), (bx, by) = piece.coord_seq.to_a.values_at(0, -1)
              mx = (ax + bx) / 2.0
              my = (ay + by) / 2.0
            end

            # Half a metre to the right of the coastline is sea, to the left land.
            nx = (y2 - y1) / length * 0.5
            ny = -(x2 - x1) / length * 0.5
            [[mx + nx, my + ny, 0], [mx - nx, my - ny, 1]].each do |x, y, side|
              index = faces.index { |_, prepared, (minx, miny, maxx, maxy)| x.between?(minx, maxx) && y.between?(miny, maxy) && prepared.contains?(Geos.create_point(x, y)) }
              votes[index][side] += 1 if index
            end
          end
        end
        seas = votes.select { |_, (sea, land)| sea > land }.keys.sort.map { |index| faces[index].first }
        seas.empty? ? nil : union(seas)
      end

      def envelope(geometry)
        xs, ys = geometry.envelope.exterior_ring.coord_seq.to_a.transpose
        [xs.min, ys.min, xs.max, ys.max]
      end

      def union(geometries)
        geometries = geometries.compact
        return Geos.create_geometry_collection if geometries.empty?

        Geos.create_geometry_collection(geometries.map(&:clone)).unary_union
      end

      def polygons(geometry)
        case geometry
        when Geos::Polygon then [geometry]
        when Geos::GeometryCollection then geometry.to_a.flat_map { |part| polygons(part) }
        else []
        end
      end

      def fill_holes(polygon)
        holes = (0...polygon.num_interior_rings).map { |i| polygon.interior_ring_n(i) }
        kept = holes.select { |ring| Geos.create_polygon(ring.clone).area >= MIN_HOLE_M2 }
        Geos.create_polygon(polygon.exterior_ring.clone, *kept.map(&:clone))
      end

      def local((lng, lat)) = [(lng - @origin[0]) * @scale_x, (lat - @origin[1]) * Planar::M_PER_DEGREE]

      def lnglat((x, y)) = [(@origin[0] + (x / @scale_x)).round(6), (@origin[1] + (y / Planar::M_PER_DEGREE)).round(6)]

      def geos(geometry)
        projected = Planar.polygons(geometry).map { |rings| rings.map { |ring| ring.map { |position| local(position) } } }
        Geos::GeoJSONReader.new.read(JSON.generate("type" => "MultiPolygon", "coordinates" => projected))
      end

      def geos_lnglat(geometry) = Geos::GeoJSONReader.new.read(JSON.generate(geometry))

      # Largest part first; outer rings counter-clockwise and holes
      # clockwise, as Osm writes them.
      def to_geojson(geometry)
        parts = polygons(geometry).sort_by { |polygon| -polygon.area }.map do |polygon|
          rings = [polygon.exterior_ring] + (0...polygon.num_interior_rings).map { |i| polygon.interior_ring_n(i) }
          rings.each_with_index.map do |ring, i|
            positions = ring.coord_seq.to_a.map { |vertex| lnglat(vertex) }.chunk_while { |a, b| a == b }.map(&:first)
            Osm.orient(positions, outer: i.zero?)
          end
        end
        parts = parts.map { |rings| rings.select { |ring| ring.size >= 4 } }.reject(&:empty?)
        parts.size == 1 ? { "type" => "Polygon", "coordinates" => parts.first } : { "type" => "MultiPolygon", "coordinates" => parts }
      end
    end
  end
end
