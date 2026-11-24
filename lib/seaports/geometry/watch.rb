# frozen_string_literal: true

require "date"
require "json"
require "yaml"

require_relative "../../seaports"
require_relative "../geometry"
require_relative "candidates"
require_relative "osm"
require_relative "planar"

module Seaports
  module Geometry
    # The ports drafted and held, or skipped, because OpenStreetMap did not
    # map their terminals: data/geometry/watch.yml lists each with why, and
    # what would unblock it. Weekly, .github/workflows/watch.yml asks
    # OpenStreetMap for the named features near each that could be a
    # terminal, and raises an issue for a person when one appears that
    # nobody has looked at yet.
    #
    # Nothing here writes an outline. A feature this finds is a reason to
    # draft the port again (rake seaports:geometry_candidates), not a part of
    # it.
    #
    # What counts as looked at, so each feature is raised once:
    #
    # - the features under +known+ in watch.yml, reviewed when the port was
    #   held (a port area with no terminals in it, a terminal of the wrong
    #   port);
    # - every feature an earlier port-watch issue for the port named, in its
    #   body or a comment, open or closed. Closing an issue whose features are
    #   no use is how a person says so.
    #
    # The issues are the state: nothing to commit back to main, and nothing
    # that expires the way a workflow cache (seven days unread) or an
    # artifact (ninety days at most) does.
    module Watch
      PATH = File.join(DIR, "watch.yml")
      LABEL = "port-watch"
      MARKER = /<!-- port-watch: ([A-Z]{2}[A-Z0-9]{3}) -->/
      REF = /\b(?:node|way|relation)\/[1-9]\d*\b/
      MAX_RADIUS_KM = 40
      # Between two ports' queries, to be gentle with the public Overpass
      # instances; Osm.query already waits and retries when one is busy.
      PAUSE_SECONDS = 10

      # Areas only: a terminal's outline is a polygon, so a node tagged as one
      # cannot be drafted into a selection. A port area or an industrial area
      # counts only with a name, the sign that someone mapped it as a place.
      PORTISH = "termin|contain|port|wharf|pier|dock|berth|quay|harbou?r|puerto|porto|港|码头|碼頭|埠頭|부두|터미널"
      OPERATORS = "port|termin|harbou?r|contain|stevedor|psa|dp world|hutchison|apm|cosco|ictsi|msc|til|evergreen|transnet|marsa"
      TAGS = [
        '["man_made"="container_terminal"]', '["industrial"="container_terminal"]', '["landuse"="port"]["name"]',
        '["industrial"="port"]["name"]', '["harbour"="yes"]["name"]', '["seamark:type"="harbour"]',
        %(["landuse"="industrial"]["name"~"#{PORTISH}",i]), %(["landuse"="industrial"]["operator"~"#{OPERATORS}",i])
      ].freeze

      KEPT_TAGS = (Candidates::KEPT_TAGS + %w[man_made]).freeze

      # One watched port. +around+ is another locode whose UN/LOCODE position
      # to search from, when the terminals are far from the port's own (Busan
      # New Port, 25 km west of Busan): positions are never typed in here.
      Entry = Data.define(:locode, :name, :around, :radius_km, :reason, :unblock, :known) do
        def centre = around || locode
      end

      # A feature that could be a terminal, with the tags that say so.
      Candidate = Data.define(:ref, :name, :tags, :lat, :lng, :size_km2) do
        def url = "https://www.openstreetmap.org/#{ref}"
      end

      # What one port's run found: every candidate, the ones nobody has looked
      # at, and the open issue to comment on, if there is one.
      Result = Data.define(:entry, :found, :new, :issue, :error)

      class Invalid < StandardError; end

      module_function

      # The entries in watch.yml, checked: a typo here would watch nothing and
      # say nothing.
      def load(path = PATH)
        data = YAML.safe_load_file(path) || {}
        entries = Array(data["ports"]).map.with_index(1) { |row, index| entry(row, "#{File.basename(path)} entry #{index}") }
        duplicates = entries.map(&:locode).tally.select { |_, count| count > 1 }.keys
        raise Invalid, "#{File.basename(path)} lists #{duplicates.join(', ')} twice" unless duplicates.empty?

        entries
      end

      def entry(row, where)
        raise Invalid, "#{where} is not a mapping" unless row.is_a?(Hash)

        unknown = row.keys - %w[locode name around radius_km reason unblock known]
        raise Invalid, "#{where}: unknown keys #{unknown.join(', ')}" unless unknown.empty?

        locode = row["locode"].to_s
        raise Invalid, "#{where}: #{locode.inspect} is not a locode" unless locode.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/)
        raise Invalid, "#{where}: #{locode} is not in the table" unless Seaports.find(locode)

        around = row["around"]&.to_s
        centre = around || locode
        raise Invalid, "#{locode}: around #{around} is not in the table" if around && !Seaports.find(around)
        raise Invalid, "#{locode}: #{centre} has no position to search around" unless Seaports.coordinates(centre)

        radius = row["radius_km"]
        raise Invalid, "#{locode}: radius_km is a number of km up to #{MAX_RADIUS_KM}" unless radius.is_a?(Numeric) && radius.positive? && radius <= MAX_RADIUS_KM

        %w[name reason unblock].each { |key| raise Invalid, "#{locode}: #{key} is missing" if row[key].to_s.strip.empty? }
        known = row["known"] || {}
        raise Invalid, "#{locode}: known is a mapping of OpenStreetMap ids to names" unless known.is_a?(Hash)

        known.each_key { |ref| Osm.parse_ref(ref) }
        Entry.new(locode:, name: row["name"].to_s.strip, around:, radius_km: radius, reason: row["reason"].to_s.strip,
          unblock: row["unblock"].to_s.strip, known: known.keys.map(&:to_s))
      rescue Osm::Error => e
        raise Invalid, "#{locode}: #{e.message}"
      end

      # The named areas within the entry's radius that could be a terminal.
      def candidates(entry, http: Http.method(:get), pause: method(:sleep))
        point = Seaports.coordinates(entry.centre)
        dlat = entry.radius_km * 1000 / Planar::M_PER_DEGREE
        dlng = dlat / Math.cos(point["lat"] * Math::PI / 180.0)
        box = [point["lat"] - dlat, point["lng"] - dlng, point["lat"] + dlat, point["lng"] + dlng].map { |v| v.round(5) }
        statements = TAGS.map { |tag| "wr#{tag}(#{box.join(',')});" }.join
        elements = Osm.query("[out:json][timeout:180];(#{statements});out tags center bb;", http:, pause:)["elements"]
        elements.filter_map { |element| candidate(element) }.uniq(&:ref).sort_by(&:ref)
      end

      def candidate(element)
        tags = element["tags"] || {}
        name = tags["name:en"] || tags["name"] || tags["seamark:name"]
        return nil if element["type"] == "node" || name.to_s.strip.empty? || Candidates.leisure?(tags)

        center = element["center"] || Candidates.midpoint(element["bounds"]) || {}
        Candidate.new(ref: "#{element['type']}/#{element['id']}", name: name.strip, tags: tags.slice(*KEPT_TAGS),
          lat: center["lat"]&.round(5), lng: center["lon"]&.round(5), size_km2: Candidates.size_km2(element["bounds"]))
      end

      # { locode => [refs] } from the port-watch issues, as `gh issue list
      # --json number,state,body,comments` answers them.
      def reported(issues)
        issues.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |issue, found|
          locode = issue["body"].to_s[MARKER, 1] or next
          texts = [issue["body"], *Array(issue["comments"]).map { |comment| comment["body"] }]
          found[locode] |= texts.flat_map { |text| text.to_s.scan(REF) }
        end
      end

      # The open port-watch issue for +locode+, to comment on, or nil.
      def open_issue(issues, locode)
        issues.select { |issue| issue["state"].to_s.casecmp?("open") && issue["body"].to_s[MARKER, 1] == locode }
          .map { |issue| issue["number"] }.min
      end

      # Every OpenStreetMap id a shipped outline is built from: a terminal of
      # Los Angeles's is no news at Long Beach.
      def shipped_refs(collections)
        collections.values.flat_map { |collection| collection.fetch("features", []).flat_map { |f| Array(f.dig("properties", "osm")) } }.uniq
      end

      # One Result per entry. A port whose query fails gets its error and no
      # candidates, and the others still run.
      def run(entries, issues: [], shipped: [], http: Http.method(:get), pause: method(:sleep), out: $stdout)
        seen = reported(issues)
        entries.each_with_index.map do |entry, index|
          pause.call(PAUSE_SECONDS) if index.positive?
          found = candidates(entry, http:, pause:).reject { |candidate| shipped.include?(candidate.ref) }
          new = found.reject { |candidate| entry.known.include?(candidate.ref) || seen[entry.locode].include?(candidate.ref) }
          out.puts "#{entry.locode}: #{found.size} candidate(s), #{new.size} not looked at yet"
          Result.new(entry:, found:, new:, issue: open_issue(issues, entry.locode), error: nil)
        rescue Osm::Error => e
          out.puts "#{entry.locode}: #{e.message}"
          Result.new(entry:, found: [], new: [], issue: nil, error: e.message)
        end
      end

      # What rake seaports:watch does: reads watch.yml and the port-watch
      # issues (+issues_path+, the JSON gh issue list wrote, or nil for
      # none), asks OpenStreetMap, and writes into +out_dir+ one set of files
      # per port with features nobody has looked at:
      #
      #   KRPUS.title  the issue's title
      #   KRPUS.md     the new issue's body, or the comment's for an open one
      #   KRPUS.issue  the open issue's number, when there is one
      #
      # plus summary.md for the job's log. Answers the results; the caller
      # fails the run for the ports whose query failed, after the others
      # have been written.
      def perform(path: PATH, issues_path: nil, out_dir: "tmp/watch", geometry_dir: DIR, date: Date.today,
        http: Http.method(:get), pause: method(:sleep), out: $stdout)
        require "fileutils"
        issues = issues_path && File.exist?(issues_path) ? JSON.parse(File.read(issues_path)) : []
        collections = Dir[File.join(geometry_dir, "*.geojson")].to_h { |file| [File.basename(file, ".geojson"), JSON.parse(File.read(file))] }
        entries, outlined = load(path).partition { |entry| !collections.key?(entry.locode) }
        outlined.each { |entry| out.puts "#{entry.locode}: now outlined; take it out of #{File.basename(path)}" }

        results = run(entries, issues:, shipped: shipped_refs(collections), http:, pause:, out:)
        FileUtils.rm_rf(out_dir)
        FileUtils.mkdir_p(out_dir)
        results.reject { |result| result.new.empty? }.each do |result|
          locode = result.entry.locode
          File.write(File.join(out_dir, "#{locode}.title"), "#{title(result.entry)}\n")
          File.write(File.join(out_dir, "#{locode}.md"), result.issue ? comment_body(result, date:) : issue_body(result, date:))
          File.write(File.join(out_dir, "#{locode}.issue"), "#{result.issue}\n") if result.issue
        end
        File.write(File.join(out_dir, "summary.md"), summary(results, outlined))
        results
      end

      def summary(results, outlined = [])
        lines = results.map do |result|
          entry = result.entry
          status =
            if result.error then "not checked: #{result.error}"
            elsif result.new.empty? then "nothing new (#{result.found.size} feature(s) already looked at)"
            else "#{result.new.size} new: #{result.new.map(&:ref).join(', ')}"
            end
          "- #{entry.name} (`#{entry.locode}`): #{status}"
        end
        lines += outlined.map { |entry| "- #{entry.name} (`#{entry.locode}`): now outlined, take it out of the watch list" }
        "#{lines.join("\n")}\n"
      end

      def title(entry) = "OpenStreetMap now maps terminals at #{entry.name}"

      # A new issue's body: why the port was held, what is new, and what to do.
      def issue_body(result, date: Date.today)
        entry = result.entry
        <<~MARKDOWN
          <!-- port-watch: #{entry.locode} -->
          OpenStreetMap now maps named features at #{entry.name} (`#{entry.locode}`) that could be its terminals.

          **Why it is held:** #{entry.reason}

          **What would unblock it:** #{entry.unblock}

          #{table(result.new)}

          #{footer(result, date)}
        MARKDOWN
      end

      # A comment on the open issue, for features found since it was opened.
      def comment_body(result, date: Date.today)
        <<~MARKDOWN
          More named features at #{result.entry.name} (`#{result.entry.locode}`) that could be its terminals:

          #{table(result.new)}

          #{footer(result, date)}
        MARKDOWN
      end

      def table(candidates)
        rows = candidates.map do |candidate|
          tags = candidate.tags.except("name").map { |key, value| code("#{key}=#{value}") }.join(", ")
          size = candidate.size_km2 ? "#{candidate.size_km2} km²" : ""
          "| [#{candidate.ref}](#{candidate.url}) | #{code(candidate.name)} | #{tags} | #{size} |"
        end
        ["| Feature | Name | Tags | Bounding box |", "| --- | --- | --- | --- |", *rows].join("\n")
      end

      def footer(result, date)
        entry = result.entry
        where = entry.around ? "#{entry.around}'s UN/LOCODE position" : "the port's UN/LOCODE position"
        "Found within #{entry.radius_km} km of #{where} on #{date}, by `rake seaports:watch`. If they make usable terminals, " \
          "draft the port with `rake \"seaports:geometry_candidates[#{entry.centre},#{entry.radius_km}]\"`. If not, close this " \
          "issue, or list them under `known:` in `data/geometry/watch.yml`: the watch raises each feature once."
      end

      # A name from OpenStreetMap as a code span, so its text can neither
      # break the table nor mention anyone.
      def code(text)
        "`#{text.to_s.gsub(/[`\s]+/, ' ').strip.gsub('|', '\|')}`"
      end
    end
  end
end
