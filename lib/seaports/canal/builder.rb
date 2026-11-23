# frozen_string_literal: true

require_relative "../canal"
require_relative "../geometry/builder"

module Seaports
  class Canal
    # Turns a canal's selection, data/geometry/canals/sources/<id>.yml, into
    # its shipped outline, data/geometry/canals/<id>.geojson. The port
    # builder with three differences: no port limits or quays; a
    # +waterway+ feature, the canal's centreline, kept as lines rather than
    # grown into an area; and an +approach+ on every anchorage and pilot
    # boarding place, which says at which end ships wait there.
    #
    #   canal: suez
    #   name: Suez Canal
    #   reviewed_at: 2026-11-23
    #   ends:
    #     north: Port Said
    #     south: Suez
    #   features:
    #     - osm: [way/5038117, way/925360882]
    #       kind: waterway
    #       name: Suez Canal
    #       note: ...
    #     - osm: way/197417801
    #       kind: anchorage
    #       name: C1
    #       approach: north
    #       note: ...
    #
    # Same rule as the ports: ids only, never coordinates.
    class Builder < Geometry::Builder
      SOURCES_DIR = File.join(DIR, "sources")
      TOP_KEYS = %w[canal name reviewed_at note ends features].freeze
      FEATURE_KEYS = %w[osm kind name approach category buffer_m note reviewed_at].freeze

      def self.selection_path(id) = File.join(SOURCES_DIR, "#{id}.yml")
      def self.output_path(id) = File.join(DIR, "#{id}.geojson")

      def self.digest(selection)
        Digest::SHA256.hexdigest(Geometry::Selection.dump(selection, top_keys: TOP_KEYS, feature_keys: FEATURE_KEYS))
      end

      def self.dump_selection(selection) = Geometry::Selection.dump(selection, top_keys: TOP_KEYS, feature_keys: FEATURE_KEYS)

      def locode = @selection.fetch("canal")
      alias id locode

      def build
        check_selection!
        fetched = @shapes.call(all_refs)
        features = @selection.fetch("features").map { |entry| feature(entry, fetched) }
        ordered = features.sort_by.with_index { |f, i| [KINDS.index(f["properties"]["kind"]), i] }

        { "type" => "FeatureCollection", "canal" => id, "name" => @selection["name"], "ends" => @selection["ends"],
          "attribution" => ATTRIBUTION, "selection_digest" => self.class.digest(@selection), "features" => ordered }.compact
      end

      private

      def check_selection!
        raise Invalid, "canal #{id.inspect} is not an id like suez" unless id.to_s.match?(ID)
        raise Invalid, "#{id}: name is missing" if blank?(@selection["name"])
        raise Invalid, "#{id}: reviewed_at is missing" if blank?(@selection["reviewed_at"])

        unknown = @selection.keys - TOP_KEYS
        raise Invalid, "#{id}: unknown keys #{unknown.join(', ')}" unless unknown.empty?
        raise Invalid, "#{id}: features must be a list" unless @selection["features"].is_a?(Array)

        ends = @selection["ends"]
        unless ends.is_a?(Hash) && ends.keys.sort == %w[north south] && ends.values.none? { |name| blank?(name) }
          raise Invalid, "#{id}: ends must name the north and the south end"
        end

        waterways = @selection["features"].count { |entry| entry["kind"] == "waterway" }
        raise Invalid, "#{id}: #{waterways} waterway features, not one" unless waterways == 1

        @selection["features"].each_with_index { |entry, index| check_entry!(entry, "#{id} feature #{index + 1} (#{entry['name'] || entry['osm']})") }
      end

      def check_entry!(entry, where)
        unknown = entry.keys - FEATURE_KEYS
        raise Invalid, "#{where}: unknown keys #{unknown.join(', ')}" unless unknown.empty?
        raise Invalid, "#{where}: no osm reference" if Array(entry["osm"]).empty?
        raise Invalid, "#{where}: kind #{entry['kind'].inspect} is not one of #{KINDS.join(', ')}" unless KINDS.include?(entry["kind"])
        raise Invalid, "#{where}: no name" if blank?(entry["name"])

        if entry["kind"] == "waterway"
          extra = %w[approach category buffer_m] & entry.keys
          raise Invalid, "#{where}: a waterway takes no #{extra.join(' or ')}" unless extra.empty?
        elsif !APPROACHES.include?(entry["approach"])
          raise Invalid, "#{where}: approach #{entry['approach'].inspect} is not one of #{APPROACHES.join(', ')}"
        end
        if entry["category"] && !Geometry::ANCHORAGE_CATEGORIES.include?(entry["category"])
          raise Invalid, "#{where}: category #{entry['category']} is not one of #{Geometry::ANCHORAGE_CATEGORIES.join(', ')}"
        end
        if entry["kind"] == "pilot_boarding" && Array(entry["osm"]).size != 1
          raise Invalid, "#{where}: a pilot boarding place is one OpenStreetMap node"
        end

        check_buffer!(entry["buffer_m"], where)
      end

      # A waterway stays a line: every way's line, and a closed way's ring,
      # as one MultiLineString.
      def combine(shapes, entry, refs)
        return super unless entry["kind"] == "waterway"

        lines = shapes.flat_map do |shape|
          case shape["type"]
          when "LineString" then [shape["coordinates"]]
          when "Polygon", "MultiPolygon" then Geometry::Planar.polygons(shape).map(&:first)
          else raise Invalid, "#{id} #{refs.join(', ')}: a waterway is made of ways, not a #{shape['type']}"
          end
        end
        { "type" => "MultiLineString", "coordinates" => lines }
      end

      def properties(entry, refs, geometry, source:)
        properties = {
          "kind" => entry["kind"], "name" => entry["name"], "approach" => entry["approach"], "category" => entry["category"],
          "osm" => refs, "source" => source, "licence" => LICENCE,
          "reviewed_at" => (entry["reviewed_at"] || @selection["reviewed_at"]).to_s, "note" => entry["note"]&.strip
        }
        { "type" => "Feature", "properties" => properties.compact, "geometry" => geometry }
      end
    end
  end
end
