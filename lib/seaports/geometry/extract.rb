# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "uri"

require_relative "../http"
require_relative "osm"
require_relative "planar"

module Seaports
  module Geometry
    # OpenStreetMap from a Geofabrik extract read on this machine, instead of
    # the public Overpass API: the same question as Osm.shapes, a shape for
    # each reference, answered from a file that does not rate-limit a weekly
    # rebuild of every port and that gives the same answer every time it is
    # read.
    #
    # Geofabrik cuts the planet into regions, down to a county or a Land, and
    # publishes each as an .osm.pbf every day. For each feature this picks
    # the smallest regions that hold it, downloads each region once into
    # tmp/osm (checked against Geofabrik's .md5), pulls the features and what
    # they reference out of it with osmium-tool, and hands Osm.shape the same
    # elements Overpass's "out geom" would have, so a relation is joined into
    # rings by exactly the code that joins Overpass's.
    #
    # Build time only, like Osm. Needs osmium-tool on the PATH (brew install
    # osmium-tool, apt-get install osmium-tool).
    class Extract
      HOST = "download.geofabrik.de"
      INDEX_URL = "https://#{HOST}/index-v1.json"
      CACHE_DIR = File.expand_path("../../../tmp/osm", __dir__)
      # Geofabrik publishes every region daily. A file younger than this is
      # read again rather than downloaded, so a day's builds all read the same
      # data; OSM_EXTRACT_MAX_AGE_DAYS changes it.
      MAX_AGE_DAYS = 3
      # A region is chosen by this many of a shape's vertices, spread along
      # it: enough to see it cross a border, few enough that a terminal of
      # thousands of vertices does not take a minute against a country's.
      SAMPLE = 64
      TYPES = { "n" => "node", "w" => "way", "r" => "relation" }.freeze

      # A shape the regions read so far hold only part of.
      class Incomplete < Osm::Error; end

      # One Geofabrik region: +path+ is where it lives on the server,
      # "europe/netherlands/zuid-holland", and names it in the log.
      Region = Data.define(:id, :parent, :pbf, :geometry, :bbox, :area) do
        def path = File.dirname(URI(pbf).path).delete_prefix("/")

        # By id: a region is a hash key here, and its border can run to
        # tens of thousands of positions.
        def ==(other) = other.is_a?(Region) && other.id == id
        alias_method :eql?, :==
        def hash = id.hash

        # Whether every one of +points+, [lng, lat] pairs, is inside.
        def holds?(points)
          points.all? { |lng, lat| lng.between?(bbox[0], bbox[2]) && lat.between?(bbox[1], bbox[3]) } &&
            points.all? { |lng, lat| Planar.contains?(geometry, lng, lat) }
        end
      end

      class << self
        # Every region in Geofabrik's index-v1.json that has an extract.
        def regions(json)
          JSON.parse(json).fetch("features").filter_map do |feature|
            properties = feature["properties"]
            pbf = properties.dig("urls", "pbf") or next
            geometry = feature["geometry"]
            Region.new(id: properties["id"], parent: properties["parent"], pbf:, geometry:,
              bbox: Planar.bbox(geometry), area: Planar.area_m2(geometry))
          end
        end

        # The smallest region that holds all of +points+. Geofabrik's regions
        # nest (Zuid-Holland in the Netherlands in Europe), so a shape across
        # two counties falls to the country that holds both. Ties go to the
        # id, so the answer never depends on the index's order.
        def smallest(regions, points)
          regions.select { |region| region.holds?(points) }.min_by { |region| [region.area, region.id] } or
            raise Osm::Error, "no Geofabrik extract holds #{points.first(3).map { |p| p.join(',') }.join(' ')}"
        end

        # The sets of regions to read a shape with these +points+ from, the
        # smallest downloads first; #shapes tries the next only when the one
        # before left a part of the shape out.
        #
        # First, the smallest region holding each point, less any region
        # that holds another of them. Geofabrik cuts its extracts so that a
        # way entering a region is in it whole, so an anchorage reaching out
        # to sea past Zuid-Holland's edge is read from Zuid-Holland's 200 MB
        # rather than the Netherlands' 1.3 GB, and one off Zeebrugge from
        # Belgium rather than Europe. Then the regions that hold every point
        # between them: Zeeland and Belgium for an anchorage across the
        # border, or the Netherlands for the one off Rotterdam.
        #
        # A continent is never read unless named with OSM_REGION: Europe is
        # a 30 GB download, which no build should start by itself.
        def covers(regions, points)
          # A point out in the ocean that no region holds says nothing.
          assigned = points.group_by { |point| regions.select { |region| region.holds?([point]) }.min_by { |region| [region.area, region.id] } }
          assigned.delete(nil)
          raise Osm::Error, "no Geofabrik extract holds #{points.first.join(',')}" if assigned.empty?

          covers = [narrow(regions, assigned.keys), absorb(assigned)].map { |cover| cover.sort_by(&:path) }.uniq
          covers.reject! { |cover| cover.any? { |region| region.parent.nil? } }
          return covers unless covers.empty?

          raise Osm::Error, "only Geofabrik's #{assigned.keys.map(&:path).join(' and ')} hold #{points.first.join(',')}: " \
            "name a region with OSM_REGION to download a continent"
        end

        # At most +count+ of +points+, evenly spread and always the first
        # and last, so the same shape always gives the same sample.
        def sample(points, count = SAMPLE)
          return points if points.size <= count

          (0...count).map { |i| points[(i * (points.size - 1)) / (count - 1)] }
        end

        # Whether a cached file can be read again rather than downloaded.
        def fresh?(path, max_age_days:, now: Time.now)
          File.exist?(path) && now - File.mtime(path) < max_age_days * 86_400
        end

        # The objects in osmium's OPL output, by reference: { "way/1" =>
        # { "nodes" => [ids] } } and so on. OPL is one object per line,
        # space-separated fields each starting with a letter, which needs no
        # XML parser.
        def objects(opl)
          opl.each_line.with_object({}) do |line, found|
            fields = line.split
            next if fields.empty?

            type = TYPES[fields.first[0]] or next
            values = fields.drop(1).to_h { |field| [field[0], field[1..]] }
            found["#{type}/#{fields.first[1..]}"] =
              case type
              when "node" then { "lon" => Float(values["x"]), "lat" => Float(values["y"]) }
              when "way" then { "nodes" => values["N"].to_s.split(",").map { |ref| "node/#{ref.delete_prefix('n')}" } }
              else { "members" => values["M"].to_s.split(",").map { |member| member(member) } }
              end
          end
        end

        # The element Overpass's "out geom" answers for +ref+, from osmium's
        # objects: a node's lat and lon, a way's "geometry", a relation's
        # members with their role, a way member's geometry and a node
        # member's lat and lon. Raises when the extract is missing a part
        # rather than guessing the rest of the shape.
        def element(ref, objects, regions: [])
          type, id = Osm.parse_ref(ref)
          object = objects.fetch(ref)
          case type
          when "node" then { "type" => type, "id" => id, "lat" => object["lat"], "lon" => object["lon"] }
          when "way" then { "type" => type, "id" => id, "geometry" => geometry(ref, object, objects, regions) }
          else
            members = object["members"].map do |member|
              ref_of_member = "#{member['type']}/#{member['ref']}"
              found = objects[ref_of_member]
              case member["type"]
              when "way"
                raise Incomplete, incomplete(ref, ref_of_member, regions) unless found

                member.merge("geometry" => geometry(ref_of_member, found, objects, regions))
              # Osm.shape never reads a node member's position, so one
              # outside the extract (a label node) is no reason to stop.
              when "node" then found ? member.merge("lat" => found["lat"], "lon" => found["lon"]) : member
              else member
              end
            end
            { "type" => type, "id" => id, "members" => members }
          end
        end

        private

        # +cover+ less every region that is the parent, or the parent's
        # parent, of another in it.
        def narrow(regions, cover)
          by_id = regions.to_h { |region| [region.id, region] }
          ancestors = cover.flat_map do |region|
            chain = []
            chain << region while (region = by_id[region.parent])
            chain
          end
          cover - ancestors
        end

        # The regions of +assigned+ ({ region => its points }), less any
        # whose points a larger one among them also holds.
        def absorb(assigned)
          assigned = assigned.dup
          assigned.keys.sort_by { |region| [region.area, region.id] }.each do |region|
            home = assigned.keys.find { |other| other != region && other.area >= region.area && other.holds?(assigned[region]) }
            assigned[home] += assigned.delete(region) if home
          end
          assigned.keys
        end

        def member(text)
          type_and_id, role = text.split("@", 2)
          { "type" => TYPES.fetch(type_and_id[0]), "ref" => type_and_id[1..].to_i,
            "role" => unescape(role.to_s) }
        end

        # OPL writes anything outside plain ASCII, and its own separators,
        # as %hex%.
        def unescape(text) = text.gsub(/%(\h+)%/) { Regexp.last_match(1).hex.chr(Encoding::UTF_8) }

        def geometry(ref, way, objects, regions)
          way["nodes"].map do |node|
            point = objects[node] or raise Incomplete, incomplete(ref, node, regions)

            { "lat" => point["lat"], "lon" => point["lon"] }
          end
        end

        def incomplete(ref, part, regions)
          where = regions.empty? ? "the extract" : "Geofabrik's #{regions.map(&:path).join(' or ')}"
          "#{ref} reaches #{part}, which is not in #{where}: " \
            "the feature has grown past them, so name a region that holds it all with OSM_REGION"
        end
      end

      # +osmium+ has Open3.capture3's shape and +download+ takes a URL and a
      # path to write it to, so a test runs neither. +region+ names one
      # region (an id like "zuid-holland" or a path like
      # "europe/netherlands") to read every feature from, instead of
      # choosing.
      def initialize(cache_dir: CACHE_DIR, max_age_days: MAX_AGE_DAYS, region: nil, out: $stdout,
        osmium: Open3.method(:capture3), download: method(:stream), http: Http.method(:get), now: -> { Time.now })
        @cache_dir = cache_dir
        @max_age_days = max_age_days
        @region_name = region
        @out = out
        @osmium = osmium
        @download = download
        @http = http
        @now = now
        @pbfs = {}
      end

      # A callable with Osm.shapes's shape for Builder, which reads the
      # shipped outline and the port's position to choose regions.
      def shapes_for(locode)
        require_relative "builder"
        require_relative "../../seaports"
        path = Builder.output_path(locode)
        outline = File.exist?(path) ? JSON.parse(File.read(path)) : nil
        point = Seaports.coordinates(locode)
        position = point && [point["lng"], point["lat"]]
        ->(refs) { shapes(refs, outline:, position:, label: locode) }
      end

      # { ref => geometry } for every reference, as Osm.shapes answers it,
      # and the same errors: Osm::Error for a reference OpenStreetMap does
      # not have. +outline+ is the port's shipped FeatureCollection, or nil,
      # and +position+ its [lng, lat], or nil: together they say where to
      # look.
      #
      # A feature across two regions (an anchorage on the Scheldt, half
      # Belgian and half Dutch) is read from both and its parts joined:
      # every extract is the same OpenStreetMap data, and the region that
      # holds both is often a continent of 30 GB. One that the first regions
      # tried hold only part of, or not at all, is tried in the next ones
      # (see Extract.covers) before it is called incomplete or missing.
      def shapes(refs, outline: nil, position: nil, label: nil)
        label ||= "OpenStreetMap"
        return {} if refs.empty?

        refs.each { |ref| Osm.parse_ref(ref) }
        tries = refs.to_h { |ref| [ref, regions_for(ref, outline, position)] }
        objects = {}
        asked = Hash.new { |hash, region| hash[region] = [] }
        found = {}
        tries.values.map(&:size).max.times do |step|
          pending = refs.select { |ref| !found.key?(ref) && tries[ref][step] }
          pending.flat_map { |ref| tries[ref][step] }.uniq.sort_by(&:path).each do |region|
            wanted = pending.select { |ref| tries[ref][step].include?(region) } - asked[region]
            next if wanted.empty?

            asked[region].concat(wanted)
            # The region read first keeps an object two of them have, so the
            # answer never depends on the order the downloads finished in.
            objects = read(region, wanted, label).merge(objects)
          end
          pending.each do |ref|
            next unless objects.key?(ref)

            found[ref] = Osm.shape(self.class.element(ref, objects, regions: tries[ref][step]))
          rescue Incomplete => e
            raise unless tries[ref][step + 1]

            @out.puts "#{label}: #{e.message.split(':').first}; trying #{tries[ref][step + 1].map(&:path).join(' and ')}"
          end
        end
        # A region cached days ago beside one downloaded today: the older
        # one's objects win, which may join two versions of a feature.
        dates = asked.keys.map { |region| timestamp(pbf(region)) }.uniq
        @out.puts "#{label}: warning: the extracts read are from #{dates.sort.join(' and ')}; delete tmp/osm for one day's data" if dates.size > 1
        missing = refs - found.keys
        unless missing.empty?
          read = asked.keys.map(&:path).sort.join(", ")
          raise Osm::Error, "OpenStreetMap has no #{missing.join(', ')} in Geofabrik's #{read}: deleted, or beyond " \
            "those regions, in which case name one that holds it with OSM_REGION"
        end

        found.slice(*refs)
      end

      # The sets of regions to try +ref+ in, in order: the one named, else
      # Extract.covers of the shipped feature built from it, else, for a
      # feature the outline does not have yet (a new port, or one just added
      # to its selection), of the whole port and its own position. A feature
      # that has moved out of them, or a new one beyond the port, is then
      # missing or incomplete, and the error says to name a region.
      def regions_for(ref, outline, position)
        return [[named_region]] if @region_name

        # Derived port limits are a hull grown out to sea, not OpenStreetMap
        # data: they say nothing about where a feature is.
        mapped = (outline || {}).fetch("features", []).reject { |f| f.dig("properties", "source").to_s.start_with?("Derived") }
        feature = mapped.find { |f| Array(f.dig("properties", "osm")).include?(ref) }
        points =
          if feature
            self.class.sample(Planar.positions(feature["geometry"]))
          else
            mapped.flat_map { |f| self.class.sample(Planar.positions(f["geometry"]), 8) } + [position].compact
          end
        raise Osm::Error, "#{ref}: no shipped outline or position to choose a Geofabrik region by: name one with OSM_REGION" if points.empty?

        self.class.covers(regions, points)
      end

      def regions
        @regions ||= begin
          path = File.join(@cache_dir, "index-v1.json")
          unless self.class.fresh?(path, max_age_days: @max_age_days, now: @now.call)
            status, body, = @http.call(INDEX_URL, {})
            raise Osm::Error, "Geofabrik's index answered HTTP #{status}" unless status == 200

            FileUtils.mkdir_p(@cache_dir)
            File.binwrite(path, body)
          end
          self.class.regions(File.read(path))
        end
      end

      private

      def named_region
        @named_region ||= regions.find { |region| [region.id, region.path].include?(@region_name) } or
          raise Osm::Error, "Geofabrik has no region #{@region_name}: give its id (zuid-holland) or path (europe/netherlands/zuid-holland)"
      end

      # The region's extract, downloaded unless the cached copy is fresh, and
      # checked against Geofabrik's MD5 before it replaces it.
      def pbf(region)
        @pbfs[region.pbf] ||= begin
          uri = URI(region.pbf)
          raise Osm::Error, "#{region.pbf} is not on #{HOST}" unless uri.scheme == "https" && uri.host == HOST

          path = File.join(@cache_dir, uri.path)
          unless self.class.fresh?(path, max_age_days: @max_age_days, now: @now.call)
            FileUtils.mkdir_p(File.dirname(path))
            partial = "#{path}.part"
            # "-latest" redirects to the day's file, zuid-holland-261122,
            # whose .md5 cannot change under the download the way the
            # latest one's can.
            dated = @download.call(region.pbf, partial)
            @out.puts "Downloaded #{dated}"
            verify!(dated, partial)
            File.rename(partial, path)
          end
          path
        end
      end

      def verify!(url, path)
        status, body, = @http.call("#{url}.md5", {})
        return if status == 200 && body.to_s.split.first == Digest::MD5.file(path).hexdigest

        File.delete(path)
        raise Osm::Error, "#{url} does not match Geofabrik's MD5 (HTTP #{status}): the download was cut short, run the build again"
      end

      # The objects +refs+ name in +region+'s extract and everything they
      # reference, as Extract.objects answers them.
      def read(region, refs, label)
        pbf = pbf(region)
        @out.puts "#{label}: #{refs.size} feature(s) from Geofabrik #{region.path} " \
          "(#{(File.size(pbf) / 1_048_576.0).round(1)} MB, OpenStreetMap as of #{timestamp(pbf)})"
        ids = refs.map { |ref| ref.sub(%r{\A(\w)\w*/}, '\1') }
        stdout, stderr, status =
          begin
            @osmium.call("osmium", "getid", "--add-referenced", "--verbose-ids", "--no-progress",
              "--output-format", "opl,add_metadata=false", pbf, *ids)
          rescue Errno::ENOENT
            raise Osm::Error, "osmium-tool is not installed: brew install osmium-tool, or apt-get install osmium-tool"
          end
        # osmium exits 1 when an id is not in the file, which is an answer
        # here (a feature across two regions is missing from one, and the
        # caller names what is missing from all), and for real failures.
        # Only --verbose-ids makes it say which it was.
        unless status.success? || stderr.match?(/did not find/i)
          raise Osm::Error, "osmium getid failed on #{region.path}: #{stderr.lines.grep_v(/\A\[/).join.strip[0, 300]}"
        end

        self.class.objects(stdout)
      end

      # When Geofabrik cut the extract: the replication timestamp in its
      # header, for the build log.
      def timestamp(pbf)
        stdout, _, status = @osmium.call("osmium", "fileinfo", "--get", "header.option.osmosis_replication_timestamp", pbf)
        status.success? && !stdout.strip.empty? ? stdout.strip : "an unknown date"
      rescue Errno::ENOENT
        "an unknown date"
      end

      # GET +url+ into +path+ a chunk at a time, since a country's extract
      # runs to gigabytes, past what Http.get will hold in memory. Follows
      # redirects on Geofabrik's own host only, and answers the URL it read.
      def stream(url, path, redirects = 3)
        uri = URI(url)
        raise Osm::Error, "#{url} is not on #{HOST}" unless uri.scheme == "https" && uri.host == HOST

        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 300) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = Http::USER_AGENT
          http.request(request) do |response|
            if response.is_a?(Net::HTTPRedirection) && redirects.positive?
              return stream(URI.join(url, response["location"]).to_s, path, redirects - 1)
            end
            raise Osm::Error, "#{url} answered HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

            File.open(path, "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
          end
        end
        url
      end
    end
  end
end
