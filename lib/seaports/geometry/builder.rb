# frozen_string_literal: true

require "date"
require "json"
require "yaml"

require_relative "../geometry"
require_relative "osm"
require_relative "planar"
require_relative "selection"

module Seaports
  module Geometry
    # Turns a port's selection, data/geometry/sources/<LOCODE>.yml, into its
    # shipped outline, data/geometry/<LOCODE>.geojson.
    #
    # The selection is the reviewed part: which OpenStreetMap features are
    # this port's terminals and anchorages, what each is called, who runs
    # it and what cargo it takes. It names features by id and holds no
    # coordinates, so a person, an agent or a reader's correction can only
    # pick among shapes OpenStreetMap already has. The builder fetches those
    # shapes and writes the GeoJSON; nothing else writes it.
    #
    #   locode: NLRTM
    #   reviewed_at: 2026-11-23
    #   quays: [NLBOT, NLEUR]
    #   position_outside: why the port limits may miss UN/LOCODE's own point
    #   port_limits:
    #     derive: hull        # or osm: relation/123 alone, when OpenStreetMap maps them
    #     osm: [relation/18550095]  # with derive: also inside the hull (a basin)
    #     buffer_m: 1500
    #     note: ...
    #   features:
    #     - osm: way/597875321  # or a list, for a terminal mapped in parts
    #       kind: terminal
    #       name: Euromax Terminal
    #       operator: Hutchison Ports ECT
    #       cargo: [container]
    #       note: ...
    #
    # A way that does not close (a berth drawn as a line) becomes an area
    # only with +buffer_m+, as the hull of its points grown by that much.
    class Builder
      SOURCES_DIR = File.join(DIR, "sources")
      LICENCE = "ODbL-1.0"
      ATTRIBUTION = "© OpenStreetMap contributors, ODbL 1.0. https://www.openstreetmap.org/copyright"
      FEATURE_KEYS = Selection::FEATURE_KEYS

      class Invalid < StandardError; end

      def self.selection_path(locode) = File.join(SOURCES_DIR, "#{locode}.yml")
      def self.output_path(locode) = File.join(DIR, "#{locode}.geojson")

      def self.read_selection(path)
        YAML.safe_load_file(path, permitted_classes: [Date])
      end

      # +shapes+ answers Osm.shapes's question; a test passes a lambda.
      def initialize(selection, shapes: Osm.method(:shapes))
        @selection = selection
        @shapes = shapes
      end

      def locode = @selection.fetch("locode")

      # The FeatureCollection, as a Hash ready for JSON.
      def build
        check_selection!
        fetched = @shapes.call(all_refs)
        features = @selection.fetch("features").map { |entry| feature(entry, fetched) }
        limits = port_limits(features, fetched)
        ordered = ([limits].compact + features).sort_by.with_index { |f, i| [KINDS.index(f["properties"]["kind"]), i] }

        { "type" => "FeatureCollection", "locode" => locode, "quays" => Array(@selection["quays"]).sort,
          "attribution" => ATTRIBUTION, "position_outside" => @selection["position_outside"]&.strip, "features" => ordered }.compact
      end

      def write(path = self.class.output_path(locode))
        File.write(path, "#{self.class.dump(build)}\n")
      end

      # One feature per line: a diff of a refresh then shows which features
      # moved rather than a wall of coordinates.
      def self.dump(collection)
        head = collection.except("features").map { |key, value| "#{JSON.generate(key)}:#{JSON.generate(value)}" }
        features = collection["features"].map { |feature| JSON.generate(feature) }
        "{#{head.join(',')},\"features\":[\n#{features.join(",\n")}\n]}"
      end

      private

      def all_refs
        refs = @selection.fetch("features").flat_map { |entry| Array(entry["osm"]) }
        limits = @selection["port_limits"] || {}
        (refs + Array(limits["osm"])).uniq
      end

      def check_selection!
        raise Invalid, "locode #{locode.inspect} is not a locode" unless locode.to_s.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/)
        raise Invalid, "#{locode}: reviewed_at is missing" if blank?(@selection["reviewed_at"])

        # A typo must not pass silently: "bufer_m: 5" would otherwise become
        # the default distance with nobody told.
        unknown = @selection.keys - Selection::TOP_KEYS
        raise Invalid, "#{locode}: unknown keys #{unknown.join(', ')}" unless unknown.empty?
        raise Invalid, "#{locode}: features must be a list" unless @selection["features"].is_a?(Array)

        limits = @selection["port_limits"] || {}
        unknown = limits.keys - Selection::LIMIT_KEYS
        raise Invalid, "#{locode} port_limits: unknown keys #{unknown.join(', ')}" unless unknown.empty?

        check_buffer!(limits["buffer_m"], "#{locode} port_limits")

        @selection.fetch("features").each_with_index do |entry, index|
          where = "#{locode} feature #{index + 1} (#{entry['name'] || entry['osm']})"
          unknown = entry.keys - FEATURE_KEYS
          raise Invalid, "#{where}: unknown keys #{unknown.join(', ')}" unless unknown.empty?
          raise Invalid, "#{where}: no osm reference" if Array(entry["osm"]).empty?
          raise Invalid, "#{where}: kind #{entry['kind'].inspect} is not one of #{KINDS.join(', ')}" unless (KINDS - ["port_limits"]).include?(entry["kind"])

          bad = Array(entry["cargo"]) - CARGO
          raise Invalid, "#{where}: cargo #{bad.join(', ')} is not one of #{CARGO.join(', ')}" unless bad.empty?
          if entry["category"] && !ANCHORAGE_CATEGORIES.include?(entry["category"])
            raise Invalid, "#{where}: category #{entry['category']} is not one of #{ANCHORAGE_CATEGORIES.join(', ')}"
          end
          if entry["kind"] == "pilot_boarding" && Array(entry["osm"]).size != 1
            raise Invalid, "#{where}: a pilot boarding place is one OpenStreetMap node"
          end

          check_buffer!(entry["buffer_m"], where)
        end
      end

      def check_buffer!(value, where)
        return if value.nil? || (value.is_a?(Numeric) && value.positive? && value <= 20_000)

        raise Invalid, "#{where}: buffer_m #{value.inspect} must be a number of metres, up to 20000"
      end

      def feature(entry, fetched)
        refs = Array(entry["osm"])
        geometry = combine(refs.map { |ref| fetched.fetch(ref) }, entry, refs)
        properties(entry, refs, geometry, source: "OpenStreetMap #{refs.map { |ref| ref.sub('/', ' ') }.join(', ')}")
      end

      # Points stay points for pilot boarding places; everything else must
      # end up an area, merged into a MultiPolygon when mapped in parts.
      def combine(shapes, entry, refs)
        if entry["kind"] == "pilot_boarding"
          point = shapes.find { |shape| shape["type"] == "Point" }
          return point if point && shapes.size == 1
        end

        polygons = shapes.flat_map do |shape|
          case shape["type"]
          when "Polygon", "MultiPolygon" then Planar.polygons(shape)
          else
            buffered(shape, entry, refs)
          end
        end
        polygons.size == 1 ? { "type" => "Polygon", "coordinates" => polygons.first } : { "type" => "MultiPolygon", "coordinates" => polygons }
      end

      def buffered(shape, entry, refs)
        metres = entry["buffer_m"].to_f
        raise Invalid, "#{locode} #{refs.join(', ')} is a #{shape['type']}, not an area: give it buffer_m to draw one around it" unless metres.positive?

        points = shape["type"] == "Point" ? [shape["coordinates"]] : shape["coordinates"]
        [[Planar.convex_hull(Planar.spread(points, metres))]]
      end

      def port_limits(features, fetched)
        limits = @selection["port_limits"]
        return nil if limits.nil?

        if limits["osm"] && limits["derive"].nil?
          refs = Array(limits["osm"])
          geometry = combine(refs.map { |ref| fetched.fetch(ref) }, limits, refs)
          return properties(limits.merge("kind" => "port_limits"), refs, geometry, source: "OpenStreetMap #{refs.map { |r| r.sub('/', ' ') }.join(', ')}")
        end

        raise Invalid, "#{locode}: port_limits needs osm: or derive: hull" unless limits["derive"] == "hull"

        metres = limits.fetch("buffer_m", 1000).to_f
        # Terminals only: an anchorage or a pilot boarding place can lie 50 km
        # out, and the limits would swallow the sea between.
        inputs = features.select { |f| f["properties"]["kind"] == "terminal" }
        extra = Array(limits["osm"])
        points = inputs.flat_map { |f| Planar.positions(f["geometry"]) } +
          extra.flat_map { |ref| Planar.positions(fetched.fetch(ref)) }
        raise Invalid, "#{locode}: no terminals to derive port limits from" if points.size < 3

        geometry = { "type" => "Polygon", "coordinates" => [Planar.convex_hull(Planar.spread(points, metres))] }
        basins = extra.empty? ? "" : " and #{extra.map { |ref| ref.sub("/", " ") }.join(", ")}"
        source = "Derived: the convex hull of this port's terminals#{basins} from OpenStreetMap, grown by #{metres.round} m"
        properties(limits.merge("kind" => "port_limits"), (inputs.flat_map { |f| f["properties"]["osm"] } + extra).uniq, geometry, source:)
      end

      def properties(entry, refs, geometry, source:)
        properties = {
          "kind" => entry["kind"], "name" => entry["name"], "operator" => entry["operator"],
          "cargo" => Array(entry["cargo"]), "category" => entry["category"], "osm" => refs, "source" => source,
          "licence" => LICENCE, "reviewed_at" => (entry["reviewed_at"] || @selection["reviewed_at"]).to_s,
          "note" => entry["note"]&.strip
        }
        { "type" => "Feature", "properties" => properties.compact, "geometry" => geometry }
      end

      def blank?(value) = value.to_s.strip.empty?
    end
  end
end
