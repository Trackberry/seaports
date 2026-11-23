# frozen_string_literal: true

require_relative "../../seaports"
require_relative "osm"
require_relative "planar"

module Seaports
  module Geometry
    # The OpenStreetMap features that could be part of a port, for whoever
    # writes its selection to choose from: a person, the agent that drafts a
    # port, or a reader's correction from a map. Each comes with its id, the
    # tags that matter and a rough size, and never with its full shape: the
    # chooser picks by id, and the builder fetches the shape.
    #
    # Marinas and yacht clubs are dropped before anyone sees them. Rotterdam
    # alone has sixty, and no cargo ship berths in one.
    module Candidates
      TAGS = [
        '["landuse"="port"]', '["industrial"="port"]', '["industrial"="container_terminal"]',
        '["seamark:type"="harbour"]', '["seamark:type"="harbour_basin"]', '["seamark:type"="anchorage"]',
        '["seamark:type"="anchor_berth"]', '["seamark:type"="berth"]["name"]', '["seamark:type"="pilot_boarding"]',
        '["harbour"="yes"]', '["boundary"="port"]', '["port"]', '["landuse"="industrial"]["name"~"[Tt]ermin"]'
      ].freeze
      KEPT_TAGS = %w[name operator landuse industrial harbour port seamark:type seamark:name seamark:harbour:category
        seamark:anchorage:category seamark:berth:category cargo terminal wikidata ref].freeze
      LEISURE = /marina|yacht|sailing|rowing|watersport|jachthaven|wsv|recreat/i

      Candidate = Data.define(:ref, :tags, :lat, :lng, :size_km2)

      module_function

      # Everything within +radius_km+ of the port's own position.
      def around_port(locode, radius_km: 20, http: Http.method(:get))
        point = Seaports.coordinates(locode) or raise Osm::Error, "#{locode} has no position to search around"

        around(point["lat"], point["lng"], radius_m: radius_km * 1000, http:)
      end

      # Everything within +radius_m+ of a position, for a correction a reader
      # pinned on the map.
      def around(lat, lng, radius_m: 500, http: Http.method(:get))
        # A bounding box rather than around:, which Overpass answers several
        # times faster: a 25 km around: query over a dozen tags times out.
        dlat = radius_m / Planar::M_PER_DEGREE
        dlng = dlat / Math.cos(lat.to_f * Math::PI / 180.0)
        box = [lat.to_f - dlat, lng.to_f - dlng, lat.to_f + dlat, lng.to_f + dlng].map { |v| v.round(5) }
        filter = "(#{box.join(',')})"
        statements = TAGS.map { |tag| "nwr#{tag}#{filter};" }.join
        elements = Osm.query("[out:json][timeout:180];(#{statements});out tags center bb;", http:)["elements"]
        elements.filter_map { |element| candidate(element) }.uniq(&:ref)
      end

      def candidate(element)
        tags = element["tags"] || {}
        return nil if leisure?(tags)

        center = element["center"] || midpoint(element["bounds"]) || element
        Candidate.new(ref: "#{element['type']}/#{element['id']}", tags: tags.slice(*KEPT_TAGS),
          lat: center["lat"]&.round(5), lng: center["lon"]&.round(5), size_km2: size_km2(element["bounds"]))
      end

      def leisure?(tags)
        tags["leisure"] == "marina" || tags["seamark:harbour:category"].to_s.start_with?("marina") ||
          tags["harbour:category"].to_s.start_with?("marina") || tags["name"].to_s.match?(LEISURE)
      end

      def midpoint(bounds)
        bounds && { "lat" => (bounds["minlat"] + bounds["maxlat"]) / 2.0, "lon" => (bounds["minlon"] + bounds["maxlon"]) / 2.0 }
      end

      # The bounding box's area: an upper bound, enough to tell a quay from a
      # country.
      def size_km2(bounds)
        return nil unless bounds

        ring = [[bounds["minlon"], bounds["minlat"]], [bounds["maxlon"], bounds["minlat"]],
          [bounds["maxlon"], bounds["maxlat"]], [bounds["minlon"], bounds["maxlat"]], [bounds["minlon"], bounds["minlat"]]]
        (Planar.ring_area_m2(ring) / 1_000_000.0).round(3)
      end
    end
  end
end
