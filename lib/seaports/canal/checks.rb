# frozen_string_literal: true

require_relative "../canal"
require_relative "../geometry/checks"

module Seaports
  class Canal
    # What a canal's outline must pass, on top of the shape checks every
    # port outline passes (closed rings that do not cross themselves,
    # plausible sizes, a source, licence and review date on every feature).
    #
    # Errors: not exactly one waterway, or one that is not lines; an
    # anchorage or pilot boarding place with no name or no approach; an
    # anchorage overlapping any port's limits; and an OpenStreetMap feature
    # that is both a canal anchorage and a port's. The last two are the
    # point of a canal outline: a ship waiting for a convoy off Port Said
    # must not read as at anchor in Port Said, so a waiting area belongs to
    # the canal or to a port, never both.
    class Checks < Geometry::Checks
      # +others+ is { locode => collection } of the port outlines.
      def self.run(collection, others: {}, file_id: nil)
        new(collection, others:, file_locode: file_id).run
      end

      # Where a shipped canal outline and its selection disagree, as lines for
      # a person. See Geometry::Checks.drift.
      def self.drift(collection, selection)
        shipped = Array(collection["features"]).map do |feature|
          props = feature["properties"]
          signature(props["kind"], props["osm"], props["name"], props["approach"], [], props["category"])
        end
        selected = Array(selection["features"]).map do |entry|
          signature(entry["kind"], entry["osm"], entry["name"], entry["approach"], [], entry["category"])
        end
        lines = (selected - shipped).map { |sig| "the selection has #{sig.first} #{sig[1].join(', ')} (#{sig[2]}) and the outline does not match it" }
        lines += (shipped - selected).map { |sig| "the outline has #{sig.first} #{sig[1].join(', ')} (#{sig[2]}), which the selection does not" }
        lines << "the ends differ from the selection's" unless collection["ends"] == selection["ends"]
        lines
      end

      def run
        id = @collection["canal"]
        check_canal_header(id)
        features = Array(@collection["features"])
        features.each_with_index { |feature, index| check_canal_feature(feature, index) }
        check_quotes(features)
        waterways = features.count { |f| f.dig("properties", "kind") == "waterway" }
        @errors << "#{id} has #{waterways} waterways, not one" unless waterways == 1
        @warnings << "no anchorage mapped" if features.none? { |f| f.dig("properties", "kind") == "anchorage" }
        if @errors.empty?
          check_approaches(features)
          check_ports(features)
        end
        Geometry::Checks::Result.new(locode: id, errors: @errors.freeze, warnings: @warnings.freeze)
      end

      # Only the conflicts between this canal and the ports in +others+, as
      # error lines, whatever else is wrong with the canal: what a port build
      # asks of every shipped canal before it writes new port limits.
      def port_conflicts
        check_ports(Array(@collection["features"]))
        @errors.dup
      end

      private

      # Two anchorages that overlap must serve the same end, or a ship in
      # both would be waiting at either end depending on file order.
      def check_approaches(features)
        anchorages = features.select { |f| f["properties"]["kind"] == "anchorage" }
        anchorages.combination(2).each do |a, b|
          next if a["properties"]["approach"] == b["properties"]["approach"]
          next unless Geometry::Planar.overlap?(a["geometry"], b["geometry"])

          @errors << "anchorages #{a['properties']['name']} and #{b['properties']['name']} overlap but serve different ends"
        end
      end

      def check_canal_header(id)
        @errors << "not a FeatureCollection" unless @collection["type"] == "FeatureCollection"
        @errors << "canal #{id.inspect} is not an id like suez" unless id.to_s.match?(ID)
        @errors << "file is named #{@file_locode} but holds #{id}" if @file_locode && @file_locode != id
        @errors << "attribution is missing" if blank?(@collection["attribution"])
        @errors << "name is missing" if blank?(@collection["name"])
        ends = @collection["ends"]
        @errors << "ends must name the north and the south end" unless ends.is_a?(Hash) && ends.keys.sort == %w[north south]
      end

      def check_canal_feature(feature, index)
        props = feature["properties"] || {}
        kind = props["kind"]
        where = "#{kind} #{props['name'] || props['osm']&.join(', ') || index + 1}"
        @errors << "#{where}: kind is not one of #{KINDS.join(', ')}" unless KINDS.include?(kind)
        %w[source licence reviewed_at].each { |key| @errors << "#{where}: #{key} is missing" if blank?(props[key]) }
        @errors << "#{where}: reviewed_at #{props['reviewed_at']} is not a date" unless date?(props["reviewed_at"])
        @errors << "#{where}: no name" if blank?(props["name"])
        @warnings << "#{where}: no note" if blank?(props["note"])

        if kind == "waterway"
          check_waterway(feature["geometry"], where)
        else
          @errors << "#{where}: approach #{props['approach'].inspect} is not one of #{APPROACHES.join(', ')}" unless APPROACHES.include?(props["approach"])
          check_geometry(feature["geometry"], kind, where)
          # The ports' name rule: a canal's anchorages are named as
          # OpenStreetMap names them too.
          check_name(props, where) if kind == "anchorage"
        end
      end

      def check_waterway(geometry, where)
        type = geometry && geometry["type"]
        return @errors << "#{where}: geometry is a #{type.inspect}, not a MultiLineString" unless type == "MultiLineString"

        lines = geometry["coordinates"]
        return @errors << "#{where}: the waterway has no lines" unless lines.is_a?(Array) && !lines.empty? && lines.all?(Array)

        lines.each do |line|
          next @errors << "#{where}: a line has fewer than two positions" if line.size < 2

          line.each { |position| check_position(position, where) }
        end
      end

      # A port's anchorages often lie outside its limits, out at sea, so a
      # canal anchorage is checked against those as well as the limits.
      PORT_AREAS = %w[port_limits anchorage].freeze

      def check_ports(features)
        anchorages = features.select { |f| f.dig("properties", "kind") == "anchorage" }
        @others.each do |locode, collection|
          port_features = Array(collection["features"])
          port_refs = port_features.flat_map { |f| Array(f.dig("properties", "osm")) }
          features.each do |feature|
            props = feature["properties"] || {}
            shared = Array(props["osm"]) & port_refs
            @errors << "#{props['kind']} #{props['name']}: #{shared.join(', ')} is also in #{locode}'s outline" unless shared.empty?
          end
          areas = port_features.select { |f| PORT_AREAS.include?(f.dig("properties", "kind")) }
          anchorages.each do |anchorage|
            areas.each do |area|
              next unless Geometry::Planar.overlap?(anchorage["geometry"], area["geometry"])

              what = area["properties"]["kind"] == "port_limits" ? "port limits" : "anchorage #{area['properties']['name']}"
              @errors << "anchorage #{anchorage['properties']['name']} overlaps #{locode}'s #{what}"
            end
          end
        end
      end
    end
  end
end
