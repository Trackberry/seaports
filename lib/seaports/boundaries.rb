# frozen_string_literal: true

require "json"

module Seaports
  # Which subdivision a point falls in, from Natural Earth's admin-1 map.
  #
  # UN/LOCODE leaves the subdivision blank for about a quarter of its ports,
  # Amsterdam among them, but publishes coordinates for half of those. Natural
  # Earth's states-and-provinces layer (public domain) tags each polygon with
  # its ISO 3166-2 code, so a port with a position can be placed in one.
  #
  # Build-time only, like Seaports::Subdivisions: the 40 MB map is read when
  # the table is built and the codes it finds are written into the table.
  class Boundaries
    # Pinned to a commit rather than master, so the map only changes when
    # someone moves this line and reads what moved with it. ca96624 (June
    # 2022) is master's head at the time of pinning.
    SOURCE_URL = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/ca96624a56bd078437bca8184e78163e5039ad19/geojson/ne_10m_admin_1_states_provinces.geojson"

    # UN/LOCODE gives positions to the minute, about two kilometres, and a
    # port's position is usually its waterfront, so a fair share of ports land
    # just offshore of the coastline Natural Earth drew. Within this distance
    # of a subdivision of the port's own country, the port is placed in the
    # nearest one; further out, it gets none rather than a guess.
    NEAREST_WITHIN_KM = 10

    KM_PER_DEGREE_LAT = 110.57
    KM_PER_DEGREE_LNG = 111.32

    # +codes+ is the area's own ISO 3166-2 code, then the codes of what it
    # sits in, as far as Natural Earth records them. The map is a few years
    # behind ISO in places (Northern Ireland's districts were merged in 2015
    # and it still draws the old ones), so when the area's own code has been
    # retired, its parent still places the port: Larne is gone, but it was in
    # GB-NIR.
    Area = Data.define(:codes, :polygons, :bbox) do
      def country
        codes.first[0, 2]
      end
    end

    CODE = /\A[A-Z]{2}-[A-Z0-9]{1,3}\z/

    def self.parse(geojson)
      areas = JSON.parse(geojson).fetch("features").filter_map do |feature|
        codes = codes_of(feature.fetch("properties"))
        next if codes.empty?

        polygons = polygons_of(feature["geometry"])
        next if polygons.empty?

        Area.new(codes: codes, polygons: polygons, bbox: bbox(polygons))
      end
      new(areas)
    end

    # The area's code, then its region's ("ES.VC" is written with a dot), then,
    # for the UK, its nation (gu_a3 is "ENG", "NIR", "SCT" or "WLS").
    #
    # Areas whose own code is not shaped like ISO 3166-2 (Natural Earth's
    # placeholders: "BA-X01" for Republika Srpska's municipalities, Kosovo's
    # "XK-" codes, "-99") are skipped entirely, so a port inside one but
    # within 10 km of a coded neighbour is placed in the neighbour. No port in
    # the shipped table is today.
    def self.codes_of(properties)
      code = properties["iso_3166_2"].to_s
      return [] unless code.match?(CODE)

      country = code[0, 2]
      region = properties["region_cod"].to_s.tr(".", "-")
      nation = country == "GB" ? "GB-#{properties['gu_a3']}" : ""
      [code, region, nation].select { |candidate| candidate.match?(CODE) && candidate.start_with?("#{country}-") }.uniq
    end

    # [[outer ring, hole, …], …] for a Polygon or MultiPolygon, each ring an
    # array of [lng, lat].
    def self.polygons_of(geometry)
      case geometry&.fetch("type")
      when "Polygon" then [geometry.fetch("coordinates")]
      when "MultiPolygon" then geometry.fetch("coordinates")
      else []
      end
    end

    def self.bbox(polygons)
      points = polygons.flat_map(&:first)
      lngs = points.map(&:first)
      lats = points.map(&:last)
      [lngs.min, lats.min, lngs.max, lats.max]
    end

    def initialize(areas)
      @by_country = areas.group_by(&:country)
    end

    # The codes (see Area) of the +country+ subdivision containing the point,
    # or of the nearest one within NEAREST_WITHIN_KM; empty when there is
    # none. Only the port's own country is searched, so a port on a border
    # cannot be handed to its neighbour.
    def codes_at(country, lat, lng)
      areas = @by_country.fetch(country.to_s.upcase, [])
      return [] if areas.empty? || lat.nil? || lng.nil?

      containing = areas.find { |area| within_bbox?(area, lat, lng, 0) && contains?(area, lat, lng) }
      (containing || nearest(areas, lat, lng))&.codes || []
    end

    private

    # +lat_margin+ and +lng_margin+ in degrees. They differ because a degree
    # of longitude shrinks towards the poles: 10 km is 0.09° of latitude
    # anywhere, but 0.2° of longitude in northern Norway.
    def within_bbox?(area, lat, lng, lat_margin, lng_margin = lat_margin)
      min_lng, min_lat, max_lng, max_lat = area.bbox
      lng.between?(min_lng - lng_margin, max_lng + lng_margin) && lat.between?(min_lat - lat_margin, max_lat + lat_margin)
    end

    def contains?(area, lat, lng)
      area.polygons.any? do |outer, *holes|
        inside?(outer, lat, lng) && holes.none? { |hole| inside?(hole, lat, lng) }
      end
    end

    # Ray casting: a point is inside a ring if a ray from it crosses the ring
    # an odd number of times.
    def inside?(ring, lat, lng)
      inside = false
      ring.each_cons(2) do |(x1, y1), (x2, y2)|
        next unless (y1 > lat) != (y2 > lat)

        crossing = x1 + ((lat - y1) * (x2 - x1) / (y2 - y1))
        inside = !inside if lng < crossing
      end
      inside
    end

    # Longitudes are compared as given, so a port a few kilometres across the
    # antimeridian from its coast (Fiji, Chukotka) is left unplaced. It is
    # never placed wrongly.
    def nearest(areas, lat, lng)
      lat_margin = NEAREST_WITHIN_KM / KM_PER_DEGREE_LAT
      lng_margin = NEAREST_WITHIN_KM / (KM_PER_DEGREE_LNG * [Math.cos(lat * Math::PI / 180), 0.01].max)
      best = areas.select { |area| within_bbox?(area, lat, lng, lat_margin, lng_margin) }
        .map { |area| [area, distance_km(area, lat, lng)] }
        .min_by(&:last)
      best && best.last <= NEAREST_WITHIN_KM ? best.first : nil
    end

    # Shortest distance from the point to any edge of the area, on a flat
    # projection centred on the point. Over ten kilometres the earth's
    # curvature is far below the source's own two-kilometre precision.
    #
    # Hole edges count as edges, so a port inside a hole (a lake, or an
    # enclave the map does not code) but within 10 km of its shore is placed
    # in the area around it. That is the right answer for a lake port.
    def distance_km(area, lat, lng)
      scale = Math.cos(lat * Math::PI / 180) * KM_PER_DEGREE_LNG
      area.polygons.flatten(1).flat_map { |ring| ring.each_cons(2).to_a }.map do |(x1, y1), (x2, y2)|
        segment_distance(
          (x1 - lng) * scale, (y1 - lat) * KM_PER_DEGREE_LAT,
          (x2 - lng) * scale, (y2 - lat) * KM_PER_DEGREE_LAT
        )
      end.min || Float::INFINITY
    end

    # Distance from the origin to the segment (ax, ay)–(bx, by).
    def segment_distance(ax, ay, bx, by)
      dx = bx - ax
      dy = by - ay
      length = (dx * dx) + (dy * dy)
      t = length.zero? ? 0 : (-((ax * dx) + (ay * dy)) / length).clamp(0, 1)
      Math.hypot(ax + (t * dx), ay + (t * dy))
    end
  end
end
