# frozen_string_literal: true

require "date"

require_relative "../../seaports"
require_relative "inside"
require_relative "planar"

module Seaports
  module Geometry
    # What every outline must pass before it ships, and what a reviewer
    # should look at. +errors+ fail the build (and CI); +warnings+ are gaps to
    # mention in the pull request: "no anchorage mapped", a terminal with no
    # cargo type.
    #
    # Not checked yet: that anchorages lie on water and terminals touch
    # land. Natural Earth's coastline is far too coarse for a dock, and
    # OpenStreetMap's is a 700 MB download, so that waits for the check
    # against where ships really stop.
    class Checks
      # Square metres. Generous on purpose: they catch a node mistaken for a
      # country, not a big terminal.
      SIZES = {
        "terminal" => 500..60_000_000,
        "anchorage" => 10_000..3_000_000_000,
        "port_limits" => 100_000..3_000_000_000
      }.freeze

      INSIDE_KINDS = %w[terminal pilot_boarding].freeze

      Result = Data.define(:locode, :errors, :warnings) do
        def ok? = errors.empty?
      end

      # +others+ is { locode => collection } for the overlap check.
      # +selection+, the port's, adds the check of the stored scan of what
      # lies inside the limits against what the selection accepts.
      def self.run(collection, others: {}, file_locode: nil, selection: nil)
        new(collection, others:, file_locode:, selection:).run
      end

      # The names the name rule allows a terminal or an anchorage whose
      # first-listed OpenStreetMap element has +tags+ (Osm.name_tags): its
      # name; or its name:en, when the name has letters outside the Latin
      # script and name:en exists; or, for an unnamed seamark, its
      # seamark:name; or, when OpenStreetMap gives none of these, one of
      # NEUTRAL_NAMES, with the description in the note. An element with a
      # name:en and no name is named by its name:en, as no name tag is left
      # for it to defer to.
      def self.allowed_names(tags)
        name, english, seamark = tags.values_at("name", "name:en", "seamark:name")
        return NEUTRAL_NAMES if [name, english, seamark].all? { |value| value.to_s.strip.empty? }

        allowed = [name].compact
        allowed << english if english && (name.nil? || non_latin?(name))
        allowed << seamark if seamark && name.nil?
        allowed
      end

      def self.non_latin?(text) = text.match?(/[\p{L}&&[^\p{Latin}]]/)

      # Where a shipped outline and the selection it should have been built
      # from disagree, as lines for a person: a feature missing from either
      # side or carrying other references, names or cargo, or other quays.
      # Offline, so CI can run it; it cannot see a hand-moved coordinate,
      # which geometry.yml catches by rebuilding the outline from
      # OpenStreetMap.
      def self.drift(collection, selection)
        shipped = Array(collection["features"]).reject { |f| f.dig("properties", "kind") == "port_limits" }.map do |feature|
          props = feature["properties"]
          signature(props["kind"], props["osm"], props["name"], props["operator"], props["cargo"], props["category"])
        end
        selected = Array(selection["features"]).map do |entry|
          signature(entry["kind"], entry["osm"], entry["name"], entry["operator"], entry["cargo"], entry["category"])
        end
        lines = (selected - shipped).map { |sig| "the selection has #{sig.first} #{sig[1].join(', ')} (#{sig[2]}) and the outline does not match it" }
        lines += (shipped - selected).map { |sig| "the outline has #{sig.first} #{sig[1].join(', ')} (#{sig[2]}), which the selection does not" }
        lines << "the quays differ from the selection's" unless Array(collection["quays"]).sort == Array(selection["quays"]).sort
        lines
      end

      def self.signature(kind, osm, name, operator, cargo, category)
        [kind, Array(osm).map(&:to_s).sort, name, operator, Array(cargo).sort, category]
      end

      def initialize(collection, others:, file_locode:, selection: nil)
        @collection = collection
        @others = others
        @file_locode = file_locode
        @selection = selection
        @errors = []
        @warnings = []
      end

      def run
        locode = @collection["locode"]
        check_header(locode)
        features = Array(@collection["features"])
        features.each_with_index { |feature, index| check_feature(feature, index) }
        check_quotes(features)
        check_port(locode, features) if @errors.empty?
        Result.new(locode:, errors: @errors.freeze, warnings: @warnings.freeze)
      end

      private

      def check_header(locode)
        @errors << "not a FeatureCollection" unless @collection["type"] == "FeatureCollection"
        @errors << "locode #{locode.inspect} is not in the sea-port table" unless Seaports.find(locode)
        @errors << "file is named #{@file_locode} but holds #{locode}" if @file_locode && @file_locode != locode
        @errors << "attribution is missing" if blank?(@collection["attribution"])

        Array(@collection["quays"]).each do |quay|
          @errors << "quay #{quay} is not in the sea-port table" unless Seaports.find(quay)
          @errors << "quay #{quay} is the port itself" if quay == locode
        end
      end

      def check_feature(feature, index)
        props = feature["properties"] || {}
        where = "#{props['kind']} #{props['name'] || props['osm']&.join(', ') || index + 1}"
        @errors << "#{where}: kind is not one of #{KINDS.join(', ')}" unless KINDS.include?(props["kind"])
        %w[source licence reviewed_at].each { |key| @errors << "#{where}: #{key} is missing" if blank?(props[key]) }
        @errors << "#{where}: reviewed_at #{props['reviewed_at']} is not a date" unless date?(props["reviewed_at"])
        @warnings << "#{where}: no note" if blank?(props["note"])
        check_geometry(feature["geometry"], props["kind"], where)

        case props["kind"]
        when "terminal"
          @warnings << "#{where}: no name" if blank?(props["name"])
          @warnings << "#{where}: no cargo type" if Array(props["cargo"]).empty?
        when "anchorage"
          @warnings << "#{where}: no category" if blank?(props["category"])
        end
        check_name(props, where) if NAMED_KINDS.include?(props["kind"])
      end

      # The kinds the name rule and the note claims apply to.
      NAMED_KINDS = %w[terminal anchorage].freeze
      NEUTRAL_NAMES = ["Anchorage", "Container terminal", "Berths"].freeze

      # Names are OpenStreetMap's own (Checks.allowed_names), read from the
      # tags the build stored as osm_tags, so the weekly refresh fails when
      # OpenStreetMap renames a feature. Then the note's own claims about
      # that name.
      def check_name(props, where)
        tags = props["osm_tags"]
        unless tags.is_a?(Hash)
          return @errors << "#{where}: the outline stores no OpenStreetMap names (osm_tags) to check its name against: " \
                            "rebuild it with rake seaports:geometry"
        end

        allowed = self.class.allowed_names(tags)
        unless allowed.include?(props["name"])
          given = tags.empty? ? "no name" : tags.map { |key, value| "#{key}=#{value}" }.join(", ")
          @errors << "#{where}: OpenStreetMap's #{Array(props['osm']).first} has #{given}, so the name must be " \
                     "#{allowed.map(&:inspect).join(' or ')}, not #{props['name'].inspect}"
        end
        check_claims(props, tags, where)
      end

      # "Named X in OpenStreetMap", and "OpenStreetMap names (or calls) it
      # "X"", in a feature's own note, must be what OpenStreetMap says: its
      # name, name:en or seamark:name, perhaps with a gloss in brackets after
      # it. "Named so" claims the feature's own name; "spells it "X"" that X
      # is part of one. An error, since a note that misquotes OpenStreetMap
      # says something untrue, and a rename in OpenStreetMap is the likeliest
      # reason it does.
      # The name runs to "in OpenStreetMap" within one sentence: not across a
      # semicolon, or a full stop that ends one, followed by a space and a
      # capital. A full stop after an abbreviation ("No. 5", "St. Helier")
      # ends nothing, and one with no space after it ("No.5", "Co.,ltd") is
      # part of the name. "Is not named X" claims nothing.
      SENTENCE_END = /(?<!\bNo|\bNos|\bSt|\bSte|\bMt|\bFt|\bNr|\bCo|\bDr|\bPt)\.\s+\p{Lu}/
      NAMED_CLAIM = /(?<!\bnot\s)\b[Nn]amed\s+((?:(?!\bnamed\s|;|#{SENTENCE_END}).){1,120}?)\s+in\s+(?:OpenStreetMap|OSM)\b/
      NAMES_IT_CLAIM = /\b(?:OpenStreetMap|OSM)\s+(names|calls|spells)\s+it\s+(?:"([^"]+)"|“([^”]+)”|‘([^’]+)’)/

      def check_claims(props, tags, where)
        note = props["note"].to_s
        values = tags.values
        claims = note.scan(NAMED_CLAIM).filter_map do |(text)|
          next if text.match?(/\A(for|after|as|by)\s/)

          # "Named X and tagged cargo=container in OpenStreetMap" claims X:
          # split before unquoting, so a quoted X keeps its quotes off.
          whole = unquote(text)
          first = unquote(text.split(/\s+and\s+/).first)
          whole == "so" ? [props["name"].to_s] : [whole, first].uniq
        end
        claims.each do |candidates|
          next if candidates.any? { |claim| named?(claim, values) }

          @errors << "#{where}: the note says it is named #{candidates.first.inspect} in OpenStreetMap, which has #{describe_tags(tags)}: correct the note"
        end
        note.scan(NAMES_IT_CLAIM).each do |verb, plain, curly, single|
          claim = plain || curly || single
          ok = verb == "spells" ? values.any? { |value| value.include?(claim) } : named?(claim, values)
          next if ok

          @errors << "#{where}: the note says OpenStreetMap #{verb} it #{claim.inspect}, but it has #{describe_tags(tags)}: correct the note"
        end
      end

      # A quoted name in a note (in "straight" or “curly” quotes) that is
      # close to a terminal's or an anchorage's name but no longer equals it
      # or anything OpenStreetMap calls it: a note left behind by a rename.
      # And, in a feature's own note, a quoted name that is neither its name
      # nor OpenStreetMap's. Warnings: a note quotes other things too.
      def check_quotes(features)
        named = features.select { |f| NAMED_KINDS.include?(f.dig("properties", "kind")) }.map { |f| f["properties"] }
        names = named.map { |props| props["name"].to_s }.reject(&:empty?)
        # The places the limits scan found are quoted too: a "Port" label.
        places = features.flat_map { |f| Array(f.dig("properties", "inside", "places")).map { |place| place["name"] } }
        known = names + named.flat_map { |props| (props["osm_tags"] || {}).values } + places.compact
        features.each do |feature|
          props = feature["properties"] || {}
          own = NAMED_KINDS.include?(props["kind"]) ? [props["name"].to_s] + (props["osm_tags"] || {}).values : nil
          quotes(props["note"]).each do |quoted|
            next if known.include?(quoted) || (own && own.any? { |value| value.include?(quoted) })

            near = names.find { |name| name.length >= 3 && quoted.length >= 3 && (quoted.downcase.include?(name.downcase) || name.downcase.include?(quoted.downcase)) }
            where = props["kind"] == "port_limits" ? "the port limits" : "#{props['kind']} #{props['name']}"
            if near
              @warnings << "#{where}: the note quotes #{quoted.inspect}, which is no feature's name now: is it #{near.inspect}, renamed?"
            elsif own
              @warnings << "#{where}: the note quotes #{quoted.inspect}, which is neither its name nor a name OpenStreetMap gives it"
            end
          end
        end
      end

      def quotes(note) = note.to_s.scan(/"([^"]{2,120})"|“([^”]{2,120})”/).map { |plain, curly| plain || curly }

      def unquote(text) = text.strip.sub(/\A"(.*)"\z/) { Regexp.last_match(1) }.sub(/\A“(.*)”\z/) { Regexp.last_match(1) }

      # +claim+ is one of +values+, or one of them with a gloss after it
      # in brackets: "River Trade Terminal (內河貨運碼頭)".
      def named?(claim, values)
        return true if values.include?(claim)

        head = claim[/\A(.+?)\s+\(.+\)\z/, 1]
        head ? values.include?(head) : false
      end

      def describe_tags(tags)
        tags.empty? ? "no name for it" : tags.map { |key, value| "#{key}=#{value.inspect}" }.join(", ")
      end

      def check_geometry(geometry, kind, where)
        type = geometry && geometry["type"]
        if kind == "pilot_boarding"
          return @errors << "#{where}: a pilot boarding place must be a Point" unless type == "Point"

          return check_position(geometry["coordinates"], where)
        end
        return @errors << "#{where}: geometry is a #{type.inspect}, not a Polygon or MultiPolygon" unless %w[Polygon MultiPolygon].include?(type)

        Planar.polygons(geometry).each do |rings|
          rings.each do |ring|
            next @errors << "#{where}: a ring has fewer than four positions" if ring.size < 4
            next @errors << "#{where}: a ring does not close" unless ring.first == ring.last

            ring.each { |position| check_position(position, where) }
            @errors << "#{where}: a ring crosses itself" if self_intersecting?(ring)
          end
        end

        range = SIZES[kind]
        area = Planar.area_m2(geometry)
        @errors << "#{where}: #{(area / 1_000_000.0).round(3)} km² is not a plausible size" if range && !range.cover?(area)
      end

      def check_position(position, where)
        lng, lat = position
        valid = lng.is_a?(Numeric) && lat.is_a?(Numeric) && lng.between?(-180, 180) && lat.between?(-90, 90)
        @errors << "#{where}: #{position.inspect} is not a position" unless valid
      end

      def check_port(locode, features)
        limits = features.select { |f| f["properties"]["kind"] == "port_limits" }
        return @errors << "#{locode} has #{limits.size} port limits, not one" unless limits.size == 1

        outline = limits.first["geometry"]
        point = Seaports.coordinates(locode)
        if point && !Planar.contains?(outline, point["lng"], point["lat"])
          message = "the port limits do not contain the port's own position (#{point['lat']}, #{point['lng']})"
          # Reviewed: UN/LOCODE places some ports on the city centre, beyond
          # the last quay. The reason ships in the file, for whoever reads it.
          reason = @collection["position_outside"]
          reason.to_s.strip.empty? ? @errors << message : @warnings << "#{message}: #{reason}"
        end

        features.each do |feature|
          kind = feature["properties"]["kind"]
          next unless INSIDE_KINDS.include?(kind)

          lng, lat = Planar.label_point(feature["geometry"])
          @warnings << "#{kind} #{feature['properties']['name']}: outside the port limits" unless Planar.contains?(outline, lng, lat)
        end
        check_inside(limits.first["properties"])
        check_isolated_terminals(features)
        check_clipped(limits.first, features) if limits.first["properties"]["clip"] == "water"
        @warnings << "no anchorage mapped" if features.none? { |f| f["properties"]["kind"] == "anchorage" }
        @warnings << "no terminal mapped" if features.none? { |f| f["properties"]["kind"] == "terminal" }
        check_overlaps(locode, features)
      end

      # Every limits outline stores the scan of what OpenStreetMap maps
      # inside (Inside), and with the selection given, the scan must hold no
      # more than the selection accepts (Inside.compare).
      def check_inside(props)
        scan = props["inside"]
        unless scan.is_a?(Hash)
          return @errors << "the port limits store no scan of what lies inside them: rebuild with rake seaports:geometry"
        end
        return unless @selection

        errors, warnings = Inside.compare(scan, @selection.dig("port_limits", "accepts"))
        @errors.concat(errors)
        @warnings.concat(warnings)
      end

      # A terminal far from every other terminal of its port is almost always
      # one picked from a neighbouring port's search: Antwerp shipped a
      # Containerkade near Vlissingen, 30 km from its nearest Antwerp quay,
      # and the derived limits stretched down the Scheldt to take it in.
      ISOLATED_M = 25_000

      def check_isolated_terminals(features)
        points = features.select { |f| f["properties"]["kind"] == "terminal" }.map do |feature|
          [feature["properties"]["name"] || feature["properties"]["osm"]&.join(", "), Planar.label_point(feature["geometry"])]
        end
        return if points.size < 2

        points.each do |name, point|
          nearest = points.reject { |_, other| other.equal?(point) }.map { |_, other| Planar.distance_m(point, other) }.min
          next if nearest <= ISOLATED_M

          @errors << "terminal #{name} is #{(nearest / 1000).round} km from the port's nearest other terminal: is it this port's?"
        end
      end

      # Limits cut to the water (clip: water) must keep every terminal whole,
      # and be one body of water unless the selection says why not
      # (disjoint): a part on its own is usually a terminal whose water
      # OpenStreetMap does not map as an area, not a second port. That every
      # terminal has water beside it is checked by the build, which has the
      # water (Clip#dry_terminals); the shipped file does not.
      def check_clipped(limits, features)
        outline = limits["geometry"]
        features.each do |feature|
          next unless feature["properties"]["kind"] == "terminal"

          positions = Planar.polygons(feature["geometry"]).flat_map(&:first)
          next if positions.all? { |lng, lat| Planar.contains?(outline, lng, lat) }

          name = feature["properties"]["name"] || feature["properties"]["osm"]&.join(", ")
          @errors << "terminal #{name}: cut by the port limits, which must keep it whole"
        end
        parts = Planar.polygons(outline).size
        reason = !blank?(limits["properties"]["disjoint"])
        @warnings << "the port limits are one part, so disjoint no longer applies" if parts == 1 && reason
        return if parts == 1 || reason

        @errors << "the port limits are #{parts} separate parts: say why with disjoint, or map the water that joins them"
      end

      # A terminal of this port inside another port's limits is a terminal
      # that will be filed under the wrong port, which is the bug outlines
      # exist to fix. Overlapping limits alone are only worth a look:
      # neighbouring ports do share water.
      def check_overlaps(locode, features)
        mine = features.find { |f| f["properties"]["kind"] == "port_limits" }["geometry"]
        box = Planar.bbox(mine)
        @others.each do |other, collection|
          next if other == locode

          theirs = Array(collection["features"]).find { |f| f.dig("properties", "kind") == "port_limits" }
          next unless theirs && Planar.bboxes_overlap?(box, Planar.bbox(theirs["geometry"]))
          # The shapes, not their boxes: Lagos's two ports have overlapping
          # boxes along the lagoon and limits that never meet.
          @warnings << "the port limits overlap #{other}'s" if Planar.intersects?(mine, theirs["geometry"])
          features.each do |feature|
            next unless feature["properties"]["kind"] == "terminal"

            lng, lat = Planar.label_point(feature["geometry"])
            next unless Planar.contains?(theirs["geometry"], lng, lat) && !Array(collection["quays"]).include?(locode)

            @errors << "terminal #{feature['properties']['name']} is inside #{other}'s port limits"
          end
        end
      end

      # Every pair of non-adjacent edges whose spans of longitude overlap,
      # found by sweeping the edges in order of their west end: a clipped
      # coastline can run to thousands of positions, where every pair would
      # be millions.
      def self_intersecting?(ring)
        edges = ring.each_cons(2).to_a
        last = edges.size - 1
        order = edges.each_index.sort_by { |i| edges[i].map(&:first).min }
        order.each_with_index.any? do |i, position|
          east = edges[i].map(&:first).max
          order[(position + 1)..].any? do |j|
            break false if edges[j].map(&:first).min > east
            next false if (i - j).abs < 2 || [i, j].minmax == [0, last]

            Planar.segments_cross?(edges[i], edges[j])
          end
        end
      end

      def date?(value)
        Date.iso8601(value.to_s)
        true
      rescue Date::Error
        false
      end

      def blank?(value) = value.to_s.strip.empty?
    end
  end
end
