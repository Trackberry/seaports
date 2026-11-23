# frozen_string_literal: true

require "date"

require_relative "../../seaports"
require_relative "planar"

module Seaports
  module Geometry
    # What every outline must pass before it ships, and what a reviewer
    # should look at. +errors+ fail the build (and CI); +warnings+ are gaps to
    # mention in the pull request: "no anchorage mapped", a terminal with no
    # cargo type.
    #
    # Not checked yet: that anchorages lie on water and terminals touch
    # land. Natural Earth's coastline is far too coarse for a dock, and
    # OpenStreetMap's is a 700 MB download, so that waits for the check
    # against where ships really stop.
    class Checks
      # Square metres. Generous on purpose: they catch a node mistaken for a
      # country, not a big terminal.
      SIZES = {
        "terminal" => 500..60_000_000,
        "anchorage" => 10_000..3_000_000_000,
        "port_limits" => 100_000..3_000_000_000
      }.freeze

      INSIDE_KINDS = %w[terminal pilot_boarding].freeze

      Result = Data.define(:locode, :errors, :warnings) do
        def ok? = errors.empty?
      end

      # +others+ is { locode => collection } for the overlap check.
      def self.run(collection, others: {}, file_locode: nil)
        new(collection, others:, file_locode:).run
      end

      # Where a shipped outline and the selection it should have been built
      # from disagree, as lines for a person: a feature missing from either
      # side or carrying other references, names or cargo, or other quays.
      # Offline, so CI can run it; it cannot see a hand-moved coordinate,
      # which geometry.yml catches by rebuilding the outline from
      # OpenStreetMap.
      def self.drift(collection, selection)
        shipped = Array(collection["features"]).reject { |f| f.dig("properties", "kind") == "port_limits" }.map do |feature|
          props = feature["properties"]
          signature(props["kind"], props["osm"], props["name"], props["operator"], props["cargo"], props["category"])
        end
        selected = Array(selection["features"]).map do |entry|
          signature(entry["kind"], entry["osm"], entry["name"], entry["operator"], entry["cargo"], entry["category"])
        end
        lines = (selected - shipped).map { |sig| "the selection has #{sig.first} #{sig[1].join(', ')} (#{sig[2]}) and the outline does not match it" }
        lines += (shipped - selected).map { |sig| "the outline has #{sig.first} #{sig[1].join(', ')} (#{sig[2]}), which the selection does not" }
        lines << "the quays differ from the selection's" unless Array(collection["quays"]).sort == Array(selection["quays"]).sort
        lines
      end

      def self.signature(kind, osm, name, operator, cargo, category)
        [kind, Array(osm).map(&:to_s).sort, name, operator, Array(cargo).sort, category]
      end

      def initialize(collection, others:, file_locode:)
        @collection = collection
        @others = others
        @file_locode = file_locode
        @errors = []
        @warnings = []
      end

      def run
        locode = @collection["locode"]
        check_header(locode)
        features = Array(@collection["features"])
        features.each_with_index { |feature, index| check_feature(feature, index) }
        check_port(locode, features) if @errors.empty?
        Result.new(locode:, errors: @errors.freeze, warnings: @warnings.freeze)
      end

      private

      def check_header(locode)
        @errors << "not a FeatureCollection" unless @collection["type"] == "FeatureCollection"
        @errors << "locode #{locode.inspect} is not in the sea-port table" unless Seaports.find(locode)
        @errors << "file is named #{@file_locode} but holds #{locode}" if @file_locode && @file_locode != locode
        @errors << "attribution is missing" if blank?(@collection["attribution"])

        Array(@collection["quays"]).each do |quay|
          @errors << "quay #{quay} is not in the sea-port table" unless Seaports.find(quay)
          @errors << "quay #{quay} is the port itself" if quay == locode
        end
      end

      def check_feature(feature, index)
        props = feature["properties"] || {}
        where = "#{props['kind']} #{props['name'] || props['osm']&.join(', ') || index + 1}"
        @errors << "#{where}: kind is not one of #{KINDS.join(', ')}" unless KINDS.include?(props["kind"])
        %w[source licence reviewed_at].each { |key| @errors << "#{where}: #{key} is missing" if blank?(props[key]) }
        @errors << "#{where}: reviewed_at #{props['reviewed_at']} is not a date" unless date?(props["reviewed_at"])
        @warnings << "#{where}: no note" if blank?(props["note"])
        check_geometry(feature["geometry"], props["kind"], where)

        case props["kind"]
        when "terminal"
          @warnings << "#{where}: no name" if blank?(props["name"])
          @warnings << "#{where}: no cargo type" if Array(props["cargo"]).empty?
        when "anchorage"
          @warnings << "#{where}: no category" if blank?(props["category"])
        end
      end

      def check_geometry(geometry, kind, where)
        type = geometry && geometry["type"]
        if kind == "pilot_boarding"
          return @errors << "#{where}: a pilot boarding place must be a Point" unless type == "Point"

          return check_position(geometry["coordinates"], where)
        end
        return @errors << "#{where}: geometry is a #{type.inspect}, not a Polygon or MultiPolygon" unless %w[Polygon MultiPolygon].include?(type)

        Planar.polygons(geometry).each do |rings|
          rings.each do |ring|
            next @errors << "#{where}: a ring has fewer than four positions" if ring.size < 4
            next @errors << "#{where}: a ring does not close" unless ring.first == ring.last

            ring.each { |position| check_position(position, where) }
            @errors << "#{where}: a ring crosses itself" if self_intersecting?(ring)
          end
        end

        range = SIZES[kind]
        area = Planar.area_m2(geometry)
        @errors << "#{where}: #{(area / 1_000_000.0).round(3)} km² is not a plausible size" if range && !range.cover?(area)
      end

      def check_position(position, where)
        lng, lat = position
        valid = lng.is_a?(Numeric) && lat.is_a?(Numeric) && lng.between?(-180, 180) && lat.between?(-90, 90)
        @errors << "#{where}: #{position.inspect} is not a position" unless valid
      end

      def check_port(locode, features)
        limits = features.select { |f| f["properties"]["kind"] == "port_limits" }
        return @errors << "#{locode} has #{limits.size} port limits, not one" unless limits.size == 1

        outline = limits.first["geometry"]
        point = Seaports.coordinates(locode)
        if point && !Planar.contains?(outline, point["lng"], point["lat"])
          message = "the port limits do not contain the port's own position (#{point['lat']}, #{point['lng']})"
          # Reviewed: UN/LOCODE places some ports on the city centre, beyond
          # the last quay. The reason ships in the file, for whoever reads it.
          reason = @collection["position_outside"]
          reason.to_s.strip.empty? ? @errors << message : @warnings << "#{message}: #{reason}"
        end

        features.each do |feature|
          kind = feature["properties"]["kind"]
          next unless INSIDE_KINDS.include?(kind)

          lng, lat = Planar.label_point(feature["geometry"])
          @warnings << "#{kind} #{feature['properties']['name']}: outside the port limits" unless Planar.contains?(outline, lng, lat)
        end
        check_isolated_terminals(features)
        check_clipped(limits.first, features) if limits.first["properties"]["clip"] == "water"
        @warnings << "no anchorage mapped" if features.none? { |f| f["properties"]["kind"] == "anchorage" }
        @warnings << "no terminal mapped" if features.none? { |f| f["properties"]["kind"] == "terminal" }
        check_overlaps(locode, features)
      end

      # A terminal far from every other terminal of its port is almost always
      # one picked from a neighbouring port's search: Antwerp shipped a
      # Containerkade near Vlissingen, 30 km from its nearest Antwerp quay,
      # and the derived limits stretched down the Scheldt to take it in.
      ISOLATED_M = 25_000

      def check_isolated_terminals(features)
        points = features.select { |f| f["properties"]["kind"] == "terminal" }.map do |feature|
          [feature["properties"]["name"] || feature["properties"]["osm"]&.join(", "), Planar.label_point(feature["geometry"])]
        end
        return if points.size < 2

        points.each do |name, point|
          nearest = points.reject { |_, other| other.equal?(point) }.map { |_, other| Planar.distance_m(point, other) }.min
          next if nearest <= ISOLATED_M

          @errors << "terminal #{name} is #{(nearest / 1000).round} km from the port's nearest other terminal: is it this port's?"
        end
      end

      # Limits cut to the water (clip: water) must keep every terminal whole,
      # and be one body of water unless the selection says why not
      # (disjoint): a part on its own is usually a terminal whose water
      # OpenStreetMap does not map as an area, not a second port. That every
      # terminal has water beside it is checked by the build, which has the
      # water (Clip#dry_terminals); the shipped file does not.
      def check_clipped(limits, features)
        outline = limits["geometry"]
        features.each do |feature|
          next unless feature["properties"]["kind"] == "terminal"

          positions = Planar.polygons(feature["geometry"]).flat_map(&:first)
          next if positions.all? { |lng, lat| Planar.contains?(outline, lng, lat) }

          name = feature["properties"]["name"] || feature["properties"]["osm"]&.join(", ")
          @errors << "terminal #{name}: cut by the port limits, which must keep it whole"
        end
        parts = Planar.polygons(outline).size
        reason = !blank?(limits["properties"]["disjoint"])
        @warnings << "the port limits are one part, so disjoint no longer applies" if parts == 1 && reason
        return if parts == 1 || reason

        @errors << "the port limits are #{parts} separate parts: say why with disjoint, or map the water that joins them"
      end

      # A terminal of this port inside another port's limits is a terminal
      # that will be filed under the wrong port, which is the bug outlines
      # exist to fix. Overlapping limits alone are only worth a look:
      # neighbouring ports do share water.
      def check_overlaps(locode, features)
        mine = features.find { |f| f["properties"]["kind"] == "port_limits" }["geometry"]
        box = Planar.bbox(mine)
        @others.each do |other, collection|
          next if other == locode

          theirs = Array(collection["features"]).find { |f| f.dig("properties", "kind") == "port_limits" }
          next unless theirs && Planar.bboxes_overlap?(box, Planar.bbox(theirs["geometry"]))
          # The shapes, not their boxes: Lagos's two ports have overlapping
          # boxes along the lagoon and limits that never meet.
          @warnings << "the port limits overlap #{other}'s" if Planar.intersects?(mine, theirs["geometry"])
          features.each do |feature|
            next unless feature["properties"]["kind"] == "terminal"

            lng, lat = Planar.label_point(feature["geometry"])
            next unless Planar.contains?(theirs["geometry"], lng, lat) && !Array(collection["quays"]).include?(locode)

            @errors << "terminal #{feature['properties']['name']} is inside #{other}'s port limits"
          end
        end
      end

      # Every pair of non-adjacent edges whose spans of longitude overlap,
      # found by sweeping the edges in order of their west end: a clipped
      # coastline can run to thousands of positions, where every pair would
      # be millions.
      def self_intersecting?(ring)
        edges = ring.each_cons(2).to_a
        last = edges.size - 1
        order = edges.each_index.sort_by { |i| edges[i].map(&:first).min }
        order.each_with_index.any? do |i, position|
          east = edges[i].map(&:first).max
          order[(position + 1)..].any? do |j|
            break false if edges[j].map(&:first).min > east
            next false if (i - j).abs < 2 || [i, j].minmax == [0, last]

            Planar.segments_cross?(edges[i], edges[j])
          end
        end
      end

      def date?(value)
        Date.iso8601(value.to_s)
        true
      rescue Date::Error
        false
      end

      def blank?(value) = value.to_s.strip.empty?
    end
  end
end
