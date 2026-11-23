# frozen_string_literal: true

module Seaports
  module Geometry
    # The little plane geometry a port needs, on GeoJSON's [lng, lat] pairs.
    #
    # Treating degrees as a flat plane is wrong over an ocean and fine over a
    # port: the largest outline here is Rotterdam's, 40 km end to end, where
    # the error in a point-in-polygon answer is far below the width of a quay.
    # Distances and areas are scaled by the cosine of the latitude, which is
    # all the accuracy a "is this plausible?" check wants.
    module Planar
      EARTH_RADIUS_M = 6_371_000.0
      M_PER_DEGREE = Math::PI * EARTH_RADIUS_M / 180.0

      module_function

      # The polygons of a Polygon or MultiPolygon geometry, each a list of
      # rings (outer first, then holes), or [] for anything else.
      def polygons(geometry)
        case geometry && geometry["type"]
        when "Polygon" then [geometry["coordinates"]]
        when "MultiPolygon" then geometry["coordinates"]
        else []
        end
      end

      # Even-odd ray casting: inside the outer ring and outside every hole of
      # any one of the polygons. A point exactly on an edge may answer either
      # way, which nobody can tell apart at a quay's width.
      def contains?(geometry, lng, lat)
        polygons(geometry).any? do |rings|
          ring_contains?(rings.first, lng, lat) && rings.drop(1).none? { |hole| ring_contains?(hole, lng, lat) }
        end
      end

      def ring_contains?(ring, lng, lat)
        inside = false
        j = ring.size - 1
        ring.each_with_index do |(xi, yi), i|
          xj, yj = ring[j]
          inside = !inside if (yi > lat) != (yj > lat) && lng < ((xj - xi) * (lat - yi) / (yj - yi)) + xi
          j = i
        end
        inside
      end

      # [min_lng, min_lat, max_lng, max_lat] of every position in a geometry.
      def bbox(geometry)
        points = positions(geometry)
        return nil if points.empty?

        lngs = points.map(&:first)
        lats = points.map(&:last)
        [lngs.min, lats.min, lngs.max, lats.max]
      end

      def positions(geometry)
        case geometry && geometry["type"]
        when "Point" then [geometry["coordinates"]]
        when "LineString", "MultiPoint" then geometry["coordinates"]
        when "Polygon", "MultiPolygon" then polygons(geometry).flatten(1).flatten(1)
        else []
        end
      end

      def bboxes_overlap?(a, b)
        a[0] <= b[2] && b[0] <= a[2] && a[1] <= b[3] && b[1] <= a[3]
      end

      # Square metres, outer rings less holes.
      def area_m2(geometry)
        polygons(geometry).sum do |rings|
          rings.each_with_index.sum { |ring, i| (i.zero? ? 1 : -1) * ring_area_m2(ring) }
        end
      end

      def ring_area_m2(ring)
        return 0.0 if ring.size < 4

        scale = Math.cos(ring.first.last * Math::PI / 180.0)
        twice = ring.each_cons(2).sum { |(x1, y1), (x2, y2)| (x1 * y2) - (x2 * y1) }
        (twice / 2.0).abs * M_PER_DEGREE * M_PER_DEGREE * scale
      end

      # A point to label the feature with: a Point's own position, or a point
      # inside the largest polygon, the centre of its bounding box when that is
      # inside and otherwise the inside point of a 16 by 16 grid nearest to it.
      # An L-shaped quay's centre is often in the dock beside it.
      def label_point(geometry)
        return geometry["coordinates"] if geometry["type"] == "Point"

        largest = polygons(geometry).max_by { |rings| ring_area_m2(rings.first) }
        return nil unless largest

        shape = { "type" => "Polygon", "coordinates" => largest }
        box = bbox(shape)
        centre = [(box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0]
        unless contains?(shape, *centre)
          grid = (0...16).to_a.product((0...16).to_a).map do |i, j|
            [box[0] + ((box[2] - box[0]) * (i + 0.5) / 16), box[1] + ((box[3] - box[1]) * (j + 0.5) / 16)]
          end
          inside = grid.select { |point| contains?(shape, *point) }
          centre = inside.min_by { |lng, lat| ((lng - centre[0])**2) + ((lat - centre[1])**2) } || centre
        end
        centre.map { |value| value.round(6) }
      end

      # Andrew's monotone chain. Returns a closed ring, counter-clockwise.
      def convex_hull(points)
        sorted = points.uniq.sort
        return [] if sorted.size < 3

        cross = ->(o, a, b) { ((a[0] - o[0]) * (b[1] - o[1])) - ((a[1] - o[1]) * (b[0] - o[0])) }
        build = lambda do |list|
          list.each_with_object([]) do |point, hull|
            hull.pop while hull.size >= 2 && cross.(hull[-2], hull[-1], point) <= 0
            hull << point
          end
        end
        lower = build.(sorted)
        upper = build.(sorted.reverse)
        ring = lower[0...-1] + upper[0...-1]
        ring + [ring.first]
      end

      # Every position pushed out by +metres+ in sixteen directions, so the
      # hull of the result is the hull of the input grown by about that much.
      def spread(points, metres)
        return points if metres.to_f <= 0

        points.flat_map do |lng, lat|
          dlat = metres / M_PER_DEGREE
          dlng = dlat / Math.cos(lat * Math::PI / 180.0)
          (0...16).map do |step|
            angle = step * Math::PI / 8
            [(lng + (dlng * Math.cos(angle))).round(6), (lat + (dlat * Math.sin(angle))).round(6)]
          end
        end
      end

      # Metres between two [lng, lat] positions, on a sphere.
      def distance_m(a, b)
        rad = Math::PI / 180.0
        dlat = (b[1] - a[1]) * rad
        dlng = (b[0] - a[0]) * rad
        h = (Math.sin(dlat / 2)**2) + (Math.cos(a[1] * rad) * Math.cos(b[1] * rad) * (Math.sin(dlng / 2)**2))
        2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(h))
      end
    end
  end
end
