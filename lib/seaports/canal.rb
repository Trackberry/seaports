# frozen_string_literal: true

require "json"

require_relative "geometry/planar"

module Seaports
  # A ship canal's outline: the canal's own waterway, the anchorages where
  # ships wait to enter it, and its pilot boarding places, one GeoJSON file
  # per canal in data/geometry/canals.
  #
  # A canal is not a port. Ships anchored off Port Said in the C and V areas
  # are waiting for a Suez convoy, not for a berth at Port Said, and a tracker
  # that files them under the port reads a canal queue as port congestion.
  # These outlines are what tells the two apart: a position inside one of a
  # canal's anchorages is a ship waiting to transit, and +approach+ says at
  # which end.
  #
  # The same rule as the port outlines: every shape is an OpenStreetMap
  # feature chosen by id in data/geometry/canals/sources and fetched by
  # `rake seaports:geometry`, © OpenStreetMap contributors under the ODbL.
  #
  #   suez = Seaports.canal("suez")
  #   suez.anchorages.size                 # => 139
  #   suez.anchorage_at(31.3583, 32.3346)  # => #<data Seaports::Canal::Area name="C1" approach="north" ...>
  #   suez.end_name("north")               # => "Port Said"
  #   Seaports.canal_anchorage_at(31.3583, 32.3346)&.canal  # => "suez"
  Canal = Data.define(:id, :name, :ends, :collection, :areas, :box) do
    # The canal's centreline as OpenStreetMap maps it, a MultiLineString.
    # It has no area: ask an anchorage, not the waterway, whether a ship is
    # waiting.
    def waterway = areas.find { |area| area.kind == "waterway" }

    def anchorages = areas.select { |area| area.kind == "anchorage" }

    def pilot_boarding_places = areas.select { |area| area.kind == "pilot_boarding" }

    # The anchorages that serve one end: "north", "south" or "in_transit".
    def anchorages_for(approach)
      wanted = approach.to_s
      known = Canal::APPROACHES
      raise ArgumentError, "approach must be one of #{known.join(', ')}, not #{approach.inspect}" unless known.include?(wanted)

      anchorages.select { |area| area.approach == wanted }
    end

    # The anchorage a position is in, or nil: a ship there is waiting to
    # transit, or waiting inside the canal for the convoy coming the other
    # way when its approach is "in_transit".
    def anchorage_at(lat, lng)
      return nil unless box && Geometry::Planar.bboxes_overlap?(box, [lng.to_f, lat.to_f, lng.to_f, lat.to_f])

      anchorages.find { |area| area.contains?(lat, lng) }
    end

    def waiting?(lat, lng) = !anchorage_at(lat, lng).nil?

    # What the canal calls an end: "Port Said" for Suez's "north".
    def end_name(approach) = ends[approach.to_s]
  end

  class Canal
    DIR = File.expand_path("../../data/geometry/canals", __dir__)
    KINDS = %w[waterway anchorage pilot_boarding].freeze
    # Both canals here run roughly north and south: Suez from Port Said to
    # Suez, Panama from Colón on the Atlantic to Balboa on the Pacific.
    # "in_transit" is a lake inside the canal where convoys pass each other.
    APPROACHES = %w[north south in_transit].freeze
    ID = /\A[a-z][a-z0-9_]{1,30}\z/

    # One feature of a canal's outline, with Seaports::Geometry::Area's
    # meaning for the fields they share. +approach+ is one of APPROACHES for
    # an anchorage or a pilot boarding place, nil for the waterway.
    Area = Data.define(:canal, :kind, :name, :approach, :category, :osm, :source, :licence, :reviewed_at, :note,
      :geometry, :lat, :lng) do
      def contains?(lat, lng)
        Geometry::Planar.contains?(geometry, lng.to_f, lat.to_f)
      end

      def point? = geometry["type"] == "Point"
      def line? = %w[LineString MultiLineString].include?(geometry["type"])
    end

    class << self
      # Every canal with an outline, by id.
      def all = ids.map { |id| find(id) }

      # The canal, or nil for an id with no outline. Ids are lower case:
      # "suez", "panama".
      def find(id)
        key = id.to_s.strip.downcase
        return nil unless key.match?(ID) && ids.include?(key)

        LOCK.synchronize do
          @entries ||= {}
          @entries.fetch(key) { @entries[key] = load(key) }
        end
      end

      def ids
        @ids || LOCK.synchronize { @ids ||= Dir[File.join(DIR, "*.geojson")].map { |path| File.basename(path, ".geojson") }.sort.freeze }
      end

      # The canal anchorage a position is in, whichever canal it belongs to,
      # or nil.
      def anchorage_at(lat, lng)
        all.each do |canal|
          area = canal.anchorage_at(lat, lng)
          return area if area
        end
        nil
      end

      # Forget what was read, for a test that writes its own files into DIR.
      def reset!
        LOCK.synchronize do
          @entries = {}
          @ids = nil
        end
      end

      private

      LOCK = Mutex.new

      def load(key)
        data = deep_freeze(JSON.parse(File.read(File.join(DIR, "#{key}.geojson"))))
        areas = data["features"].map { |feature| area(key, feature) }.freeze
        anchorages = areas.select { |area| area.kind == "anchorage" }
        box = anchorages.empty? ? nil : anchorages.map { |area| Geometry::Planar.bbox(area.geometry) }.transpose.then do |b|
          [b[0].min, b[1].min, b[2].max, b[3].max].freeze
        end
        Canal.new(id: key, name: data["name"], ends: data["ends"] || {}.freeze, collection: data, areas:, box:)
      end

      def area(canal, feature)
        props = feature["properties"]
        lng, lat = Geometry::Planar.label_point(feature["geometry"])
        Area.new(canal:, kind: props["kind"], name: props["name"], approach: props["approach"], category: props["category"],
          osm: props["osm"] || [].freeze, source: props["source"], licence: props["licence"],
          reviewed_at: props["reviewed_at"], note: props["note"], geometry: feature["geometry"], lat:, lng:)
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
