# frozen_string_literal: true

require "csv"
require "json"
require "set"

module Seaports
  # Which IANA time zone a port keeps its clock in: "Europe/Madrid" for
  # Valencia, "Atlantic/Canary" for Las Palmas.
  #
  # A tracking feed that sends a local time with no offset ("arrives 05:30"),
  # or an offset taken in winter for a call made in summer, can only be read
  # right with the port's zone, which gives the offset for any date. UN/LOCODE
  # publishes none, so it is worked out here, best first:
  #
  # - override: a reviewed row in data/sources/timezone_overrides.csv;
  # - country: the country's zone, when tzdata gives the country only one,
  #   which is most of them and needs no position. Every Dutch port is in
  #   Europe/Amsterdam, wherever UN/LOCODE put it;
  # - map: the zone the port's position falls in on timezone-boundary-builder's
  #   map, when it is one of the country's;
  # - nearest: else the nearest of the country's zones, within
  #   NEAREST_WITHIN_KM of a position on someone's land or territorial sea (a
  #   border port whose coarse position lands next door: Detroit, on the
  #   Canadian side of its river), or OFFSHORE_WITHIN_KM of one out at sea (an
  #   oil terminal on the North West Shelf);
  # - subdivision: for a port nothing above places, the zone every port the
  #   map placed in the same subdivision is in, when at least
  #   SUBDIVISION_MINIMUM of them are and they all agree. Bavaria's are all in
  #   Europe/Berlin, so a Bavarian port with no position is too; Florida's are
  #   split between New York and Chicago, so one with no position gets none.
  #
  # A zone is only ever one tzdata lists for the port's country (zone.tab),
  # so a Spanish port is in Europe/Madrid, Africa/Ceuta or Atlantic/Canary and
  # nothing else. A country zone.tab does not list (XZ, installations in
  # international waters) takes whatever zone the map has, the ocean's
  # Etc/GMT ones included.
  #
  # Build-time only, like Seaports::Boundaries: the map is 176 MB and needs
  # GEOS, through the rgeo gem. The zones it finds are written into the table,
  # and the gem reads them as strings.
  class Timezones
    # Pinned, like the other sources, so the map only changes when someone
    # moves this line, and with it zone.tab from the same tzdata release.
    RELEASE = "2026f"
    SOURCE_URL = "https://github.com/evansiroky/timezone-boundary-builder/releases/download/#{RELEASE}/timezones-with-oceans.geojson.zip"

    # tzdata's zone.tab, vendored from the same release as the map: the zones
    # each country uses. tzdata calls it deprecated in favour of
    # zone1970.tab, which files several countries under one zone; zone.tab
    # keeps one country per zone, with the names the map draws
    # (Europe/Copenhagen, which tzdata has linked to Europe/Berlin since
    # 2022b). Public domain.
    ZONE_TAB_PATH = File.expand_path("../../data/sources/zone.tab", __dir__)
    ZONE_TAB_URL = "https://raw.githubusercontent.com/eggert/tz/#{RELEASE}/zone.tab"

    OVERRIDES_PATH = File.expand_path("../../data/sources/timezone_overrides.csv", __dir__)

    NEAREST_WITHIN_KM = 50
    OFFSHORE_WITHIN_KM = 250
    SUBDIVISION_MINIMUM = 3

    # A GEOS distance is in degrees, read here as degrees of latitude. A
    # degree of longitude is shorter by the cosine of the latitude, so a
    # distance read this way is never shorter than the true one, and the
    # reach east-west is that much less than the figures above: 25 and 125 km
    # at 60° N. Short of the reach, never past it.
    KM_PER_DEGREE = 111.32

    # The map's zones for the open sea, past every country's territorial
    # waters: Etc/GMT+5, Etc/GMT-8 and so on.
    OCEAN = %r{\AEtc/}

    SOURCES = %w[override country map nearest subdivision].freeze
    BY_POSITION = %w[map nearest].freeze

    # { "ES" => ["Europe/Madrid", "Africa/Ceuta", "Atlantic/Canary"], ... }
    # from zone.tab's text.
    def self.countries(text = File.read(ZONE_TAB_PATH))
      text.each_line.with_object({}) do |line, countries|
        next if line.start_with?("#") || line.strip.empty?

        country, _, zone = line.split("\t")
        (countries[country] ||= []) << zone.strip
      end.transform_values(&:freeze).freeze
    end

    # Reads OVERRIDES_PATH (or +path+) into { locode => zone }. Typed by
    # people, so a malformed locode or zone, a missing note or a port listed
    # twice stops the build with the line to fix. Whether the zone is one of
    # the port's country is checked where the country is known: see #assign.
    def self.overrides(path = OVERRIDES_PATH)
      return {} unless File.exist?(path)

      CSV.foreach(path, headers: true).with_index(2).each_with_object({}) do |(row, line), overrides|
        locode = row["locode"].to_s.strip.upcase
        zone = row["timezone"].to_s.strip
        raise ArgumentError, "#{path}:#{line}: #{locode.inspect} is not a locode" unless locode.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/)
        raise ArgumentError, "#{path}:#{line}: #{locode} has no valid timezone" unless zone.match?(%r{\A[A-Za-z_]+(/[A-Za-z0-9_+-]+)+\z})
        raise ArgumentError, "#{path}:#{line}: #{locode} has no note" if row["note"].to_s.strip.empty?
        raise ArgumentError, "#{path}:#{line}: #{locode} is listed twice" if overrides.key?(locode)

        overrides[locode] = zone
      end
    end

    # The map is a FeatureCollection with a "tzid" on each feature.
    def self.parse(geojson, countries: self.countries)
      load_geos!
      factory = RGeo::Geos.factory(native_interface: :capi)
      zones = JSON.parse(geojson).fetch("features").filter_map do |feature|
        id = feature.dig("properties", "tzid")
        text = wkt(feature["geometry"])
        next if id.nil? || text.nil?

        [id, factory.parse_wkt(text)]
      end
      new(zones, countries, factory)
    end

    # A Polygon or MultiPolygon as WKT, which GEOS reads without a Ruby
    # object per vertex.
    def self.wkt(geometry)
      polygons =
        case geometry&.fetch("type")
        when "Polygon" then [geometry.fetch("coordinates")]
        when "MultiPolygon" then geometry.fetch("coordinates")
        end
      return nil if polygons.nil? || polygons.empty?

      text = polygons.map { |rings| "(#{rings.map { |ring| "(#{ring.map { |lng, lat| "#{lng} #{lat}" }.join(', ')})" }.join(', ')})" }
      "MULTIPOLYGON (#{text.join(', ')})"
    end

    # The release's GeoJSON is a zip holding one file. Ruby has no zip reader
    # of its own, so this asks unzip, which every machine that builds the
    # table has.
    def self.unzip(path)
      require "open3"
      text, error, status = Open3.capture3("unzip", "-p", path)
      raise "unzip #{path} failed: #{error.strip}" unless status.success?

      text
    end

    def self.load_geos!
      require "rgeo"
      return if RGeo::Geos.capi_supported?

      raise LoadError, "timezones need GEOS at build time, and the rgeo gem was installed without it: " \
                       "brew install geos (or apt-get install libgeos-dev), then gem pristine rgeo"
    end

    Zone = Data.define(:id, :geometry, :bbox)

    # One port, as #assign reads it. +path+ is its subdivision path, most
    # specific first, as the table writes it.
    Port = Data.define(:locode, :lat, :lng, :path) do
      def country = locode[0, 2]
    end

    attr_reader :countries

    # +zones+ is [[id, GEOS geometry], ...]; +countries+ as Timezones.countries.
    def initialize(zones, countries, factory)
      @factory = factory
      @countries = countries
      @zones = zones.map do |id, geometry|
        geometry.prepare! if geometry.respond_to?(:prepare!)
        Zone.new(id:, geometry:, bbox: bbox(geometry))
      end
      @ids = @zones.to_set(&:id)
    end

    # Whether +zone+ is one a port of +country+ may be in: one of its
    # zone.tab zones, or, for a country zone.tab does not list, any zone the
    # map draws.
    def valid?(country, zone)
      own = @countries[country]
      own ? own.include?(zone) : @ids.include?(zone)
    end

    # { locode => [zone, source] } for +ports+ (Timezones::Port), every
    # source one of SOURCES; [nil, nil] for a port nothing places.
    # +overrides+ is { locode => zone }, and one that is not a zone of the
    # port's country stops the build.
    def assign(ports, overrides: {})
      placed = ports.to_h do |port|
        override = overrides[port.locode]
        if override
          raise ArgumentError, "#{port.locode}: override #{override} is not a time zone of #{port.country}" unless valid?(port.country, override)

          next [port.locode, [override, "override"]]
        end
        [port.locode, zone_for(port.country, port.lat, port.lng)]
      end
      by_subdivision = subdivision_zones(ports, placed)
      ports.each do |port|
        next unless placed[port.locode].first.nil?

        zone = port.path.lazy.map { |code| by_subdivision[code] }.find { |zones| zones }
        placed[port.locode] = [zone.first, "subdivision"] if zone&.size == 1 && valid?(port.country, zone.first)
      end
      placed
    end

    # [zone, source] for one port from its own facts, the subdivision step
    # aside (it needs the others), or [nil, nil].
    def zone_for(country, lat, lng)
      own = @countries[country]
      return [own.first, "country"] if own&.size == 1
      return [nil, nil] if lat.nil? || lng.nil?

      found = zone_at(lat, lng)
      return [found, "map"] if found && (own.nil? || own.include?(found))
      return [nil, nil] if own.nil?

      within = found.nil? || found.match?(OCEAN) ? OFFSHORE_WITHIN_KM : NEAREST_WITHIN_KM
      near = nearest(own, lat, lng, within)
      near ? [near, "nearest"] : [nil, nil]
    end

    # Ports placed by their position in another zone than every other port
    # placed by position in one of their subdivisions, when there are at
    # least SUBDIVISION_MINIMUM others: [locode, zone, subdivision, their
    # zone]. Most are real exceptions (Fort Frances keeps Central time in
    # Ontario, Easter Island its own in Valparaíso); the rest are positions
    # in the wrong place, for a person to check and override. +placed+ is
    # what #assign returned.
    def disagreements(ports, placed)
      counts = subdivision_counts(ports, placed)
      ports.filter_map do |port|
        zone, source = placed[port.locode]
        next unless BY_POSITION.include?(source)

        port.path.lazy.filter_map do |code|
          others = counts[code].dup
          others[zone] -= 1
          others.delete_if { |_, count| count <= 0 }
          [port.locode, zone, code, others.keys.first] if others.size == 1 && others.keys.first != zone && others.values.first >= SUBDIVISION_MINIMUM
        end.first
      end
    end

    # The id of the zone the map has the point in, or nil.
    def zone_at(lat, lng)
      point = @factory.point(lng, lat)
      @zones.find { |zone| within_bbox?(zone, lat, lng, 0, 0) && zone.geometry.contains?(point) }&.id
    end

    private

    # { subdivision code => { zone => ports } } over the ports placed by
    # position, at every level of each one's path. Only map and nearest
    # count: a country's single zone says nothing about where a subdivision
    # is, and an override is one port's.
    def subdivision_counts(ports, placed)
      ports.each_with_object(Hash.new { |hash, code| hash[code] = Hash.new(0) }) do |port, counts|
        zone, source = placed[port.locode]
        next unless BY_POSITION.include?(source)

        port.path.each { |code| counts[code][zone] += 1 }
      end
    end

    # { subdivision code => [zones] }, for codes with at least
    # SUBDIVISION_MINIMUM ports placed by position.
    def subdivision_zones(ports, placed)
      subdivision_counts(ports, placed).select { |_, zones| zones.values.sum >= SUBDIVISION_MINIMUM }.transform_values(&:keys)
    end

    def nearest(ids, lat, lng, within_km)
      point = @factory.point(lng, lat)
      lat_margin = within_km / KM_PER_DEGREE
      lng_margin = lat_margin / [Math.cos(lat * Math::PI / 180), 0.01].max
      best = @zones.select { |zone| ids.include?(zone.id) && within_bbox?(zone, lat, lng, lat_margin, lng_margin) }
        .map { |zone| [zone.id, zone.geometry.distance(point) * KM_PER_DEGREE] }
        .min_by(&:last)
      best && best.last <= within_km ? best.first : nil
    end

    def within_bbox?(zone, lat, lng, lat_margin, lng_margin)
      min_lng, min_lat, max_lng, max_lat = zone.bbox
      lng.between?(min_lng - lng_margin, max_lng + lng_margin) && lat.between?(min_lat - lat_margin, max_lat + lat_margin)
    end

    def bbox(geometry)
      envelope = geometry.envelope
      points = envelope.respond_to?(:exterior_ring) ? envelope.exterior_ring.points : [envelope]
      [points.map(&:x).min, points.map(&:y).min, points.map(&:x).max, points.map(&:y).max]
    end
  end
end
