# frozen_string_literal: true

require "json"

require_relative "geometry/planar"

module Seaports
  # Port outlines: the port limits, anchorages, terminals and pilot boarding
  # places of a port, one GeoJSON file per locode in data/geometry.
  #
  # A point says where a port is; an outline says whether a ship is in it.
  # Ports sit up rivers (Sevilla, Huelva), run to quays 40 km from the city
  # they are named after (Rotterdam's Maasvlakte), and anchor their ships
  # more than 15 nautical miles out (Antwerp's Wielingen). A radius around one
  # point gets all of those wrong.
  #
  # No coordinate in these files was typed or generated: every shape is an
  # OpenStreetMap feature, chosen by id in data/geometry/sources and fetched
  # from OpenStreetMap by `rake seaports:geometry`, or derived from those
  # features by a stated rule (the port limits, when OpenStreetMap maps none).
  # The outlines are © OpenStreetMap contributors and published under the
  # Open Database Licence, separately from the gem's MIT code: see
  # data/geometry/LICENSE.md.
  module Geometry
    DIR = File.expand_path("../../data/geometry", __dir__)
    KINDS = %w[port_limits anchorage terminal pilot_boarding].freeze
    CARGO = %w[container reefer ro_ro bulk tanker general passenger].freeze
    ANCHORAGE_CATEGORIES = %w[general deep_water tanker explosives quarantine waiting emergency small_craft].freeze

    # One feature of a port's outline. +lat+ and +lng+ are a label point (see
    # Planar.label_point), not a test of anything; ask +contains?+ that.
    # +cargo+ is a list from CARGO, [] when nobody has said; +category+ is
    # one of ANCHORAGE_CATEGORIES for an anchorage and nil otherwise. +source+
    # names the OpenStreetMap features (+osm+, "way/597875321") the shape came
    # from, or the rule it was derived by.
    Area = Data.define(:locode, :kind, :name, :operator, :cargo, :category, :osm, :source, :licence, :reviewed_at,
      :note, :geometry, :lat, :lng) do
      def contains?(lat, lng)
        Planar.contains?(geometry, lng.to_f, lat.to_f)
      end

      def point? = geometry["type"] == "Point"
    end

    class << self
      # The parsed FeatureCollection, deep-frozen, or nil when the port has no
      # outline. Hand it to a map as it is: it is valid GeoJSON with three
      # foreign members, "locode", "quays" and "attribution".
      def collection(locode)
        entry(locode)&.first
      end

      # Every feature of the port as an Area, in file order; [] for a port
      # with no outline.
      def areas(locode)
        entry(locode)&.last || NO_AREAS
      end

      # Every locode with an outline, sorted.
      def locodes
        @locodes || LOCK.synchronize { @locodes ||= Dir[File.join(DIR, "*.geojson")].map { |path| File.basename(path, ".geojson") }.sort.freeze }
      end

      # Forget what was read, for a test that writes its own files into DIR.
      def reset!
        LOCK.synchronize do
          @entries = {}
          @locodes = nil
        end
      end

      private

      LOCK = Mutex.new
      NO_AREAS = [].freeze

      # [collection, areas] for a locode, read once; nil for a port with no
      # file. The miss is remembered too, so an unknown port costs a hash
      # lookup after the first time rather than a stat.
      def entry(locode)
        key = locode.to_s.strip.upcase
        return nil unless key.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/)

        entries = @entries || LOCK.synchronize { @entries ||= {} }
        return entries[key] if entries.key?(key)

        LOCK.synchronize { entries.key?(key) ? entries[key] : (entries[key] = load(key)) }
      end

      def load(key)
        path = File.join(DIR, "#{key}.geojson")
        return nil unless File.exist?(path)

        data = deep_freeze(JSON.parse(File.read(path)))
        [data, data["features"].map { |feature| area(key, feature) }.freeze].freeze
      end

      def area(locode, feature)
        props = feature["properties"]
        lng, lat = Planar.label_point(feature["geometry"])
        Area.new(locode:, kind: props["kind"], name: props["name"], operator: props["operator"],
          cargo: props["cargo"] || [].freeze, category: props["category"], osm: props["osm"] || [].freeze,
          source: props["source"], licence: props["licence"], reviewed_at: props["reviewed_at"], note: props["note"],
          geometry: feature["geometry"], lat:, lng:)
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }
        when Array then value.each { |v| deep_freeze(v) }
        end
        value.freeze
      end
    end
  end
end
