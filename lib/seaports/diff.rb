# frozen_string_literal: true

require "csv"

require_relative "coordinate_sources"

module Seaports
  # What a refresh actually changed, and whether it is safe to ship.
  #
  # The failure mode worth designing for is not "we missed a port". It is a bad
  # upstream release — a truncated file, a changed column, a mirror that
  # rebuilt itself wrong — landing in a gem that thousands of lookups trust. A
  # human reading a pull request cannot eyeball 17,000 rows, so the gates below
  # are the reading, and the summary is what is left to judge.
  class Diff
    # Ports large enough that their disappearance means the source broke, not
    # that the world changed. Spread across continents so a regional truncation
    # cannot slip through, and every one of them is a port a tracking feed
    # names on an ordinary day.
    ANCHORS = %w[
      AEJEA AUBNE BEANR CNSGH CNXMG COCTG DEHAM ESALG ESVLC GBFXT
      HKHKG KRPUS NLRTM NZTRG SGSIN USLAX
    ].freeze

    # Codes that must stay out. PAPCN is the Panama Canal, which UNECE files as
    # an unverified road terminal — see the note in Seaports. If a future
    # release reclassifies it as a port, that should be a decision someone
    # makes, not a row that appears quietly.
    EXCLUDED = %w[PAPCN].freeze

    MINIMUM_COUNT = 15_000

    # A real UNECE release adds and retires a handful of entries. Losing two
    # percent of the table in one go is a broken source, not a busy half-year.
    MAXIMUM_SHRINKAGE = 0.02

    def self.between(before_path, after_path)
      new(read(before_path), read(after_path))
    end

    def self.read(path)
      CSV.foreach(path, headers: true).each_with_object({}) do |row, ports|
        locode = row["locode"].to_s.strip.upcase
        next if locode.empty?

        ports[locode] = { name: row["name"].to_s.strip, point: point(row), path: path(row), source: row["coordinate_source"].to_s.strip,
                         alternates: row["alternate_names"].to_s.split("|").map(&:strip).reject(&:empty?) }
      end
    end

    # The port's subdivision chain as written, "GB-SFK GB-ENG". A table from
    # before the path column existed has only the principal, which stands in.
    def self.path(row)
      (row["subdivision_path"] || row["principal_subdivision"]).to_s.split.join(" ")
    end

    def self.point(row)
      lat = row["lat"].to_s.strip
      lng = row["lng"].to_s.strip
      return nil if lat.empty? || lng.empty?

      [lat.to_f, lng.to_f]
    end

    # A position that moves less than this is a rounding or a re-survey of the
    # same quay, not a change worth a release.
    NEGLIGIBLE_KM = 0.1

    # More than this share of the ports that had a position moving over
    # MOVED_KM in one refresh is a source that reshuffled its coordinates.
    MAXIMUM_MOVED = 0.05
    MOVED_KM = 1

    # More than this share of the ports that had a position losing it in one
    # refresh is a source that vanished or was refused wholesale, not ports
    # whose coordinates were withdrawn.
    MAXIMUM_LOST_POSITIONS = 0.02

    def initialize(before, after)
      @before = before
      @after = after
    end

    def changed?
      !(added.empty? && removed.empty? && renamed.empty? && repositioned.empty? && resubdivided.empty? && renamed_alternates.empty?)
    end

    # [locode, name, names added, names removed] for a port that kept its code
    # and changed its alternate names. A table from before the column existed
    # has none, so every name is an addition.
    def renamed_alternates
      @renamed_alternates ||= common.filter_map do |locode|
        was = @before[locode][:alternates].to_a.sort
        now = @after[locode][:alternates].to_a.sort
        [locode, @after[locode][:name], now - was, was - now] if was != now
      end
    end

    # "Alternate names: 790 ports changed (1,100 names added, 4 removed).", or
    # nil when none did. Also for the changelog.
    def names_headline
      return nil if renamed_alternates.empty?

      added = renamed_alternates.sum { |_, _, gained, _| gained.size }
      lost = renamed_alternates.sum { |_, _, _, dropped| dropped.size }
      "Alternate names: #{renamed_alternates.size} ports changed (#{added} names added, #{lost} removed)."
    end

    def added
      @added ||= (@after.keys - @before.keys).sort
    end

    def removed
      @removed ||= (@before.keys - @after.keys).sort
    end

    # [locode, was, now] for a port that kept its code and changed its name.
    def renamed
      @renamed ||= common.filter_map do |locode|
        was = @before[locode][:name]
        now = @after[locode][:name]
        [locode, was, now] if was != now
      end
    end

    # Every kind of position change in one list, tagged, because they read
    # differently downstream: a port that gains coordinates puts a new marker
    # on a map, and one that loses them takes a marker away. Both are worth
    # seeing before a release, and neither is a failure.
    def repositioned
      @repositioned ||= common.filter_map do |locode|
        was = @before[locode][:point]
        now = @after[locode][:point]
        next if was == now
        next if was && now && CoordinateSources.km(was, now) < NEGLIGIBLE_KM

        [locode, @after[locode][:name], (was.nil? ? :located : (now.nil? ? :unlocated : :moved))]
      end
    end

    # [locode, name, was, now] for a port whose subdivision path changed at
    # any level, each path a space-separated string ("" for none). A county
    # that moves inside the same nation changes Seaports.subdivision without
    # touching the principal one, and it still has to ship. Each change can
    # move a port onto another holiday calendar, so all are listed, though
    # none is a failure on its own.
    def resubdivided
      @resubdivided ||= common.filter_map do |locode|
        was = @before[locode][:path].to_s
        now = @after[locode][:path].to_s
        [locode, @after[locode][:name], was, now] if was != now
      end
    end

    # The subset of resubdivided whose principal subdivision went from one
    # code to another: placed before, placed now, somewhere else. Gaining or
    # losing a code is not in it.
    def reassigned
      @reassigned ||= resubdivided.select do |_, _, was, now|
        !was.empty? && !now.empty? && was.split.last != now.split.last
      end
    end

    # Empty means the refresh may ship. Anything here is a reason it may not,
    # written the way it should read in an issue.
    def failures
      [count_failure, shrinkage_failure, region_failure, reassignment_failure, moved_failure, positions_failure, *anchor_failures, *excluded_failures].compact
    end

    def ok?
      failures.empty?
    end

    def summary
      [
        headline,
        failures.empty? ? nil : "**Blocked**\n\n#{failures.map { |line| "- #{line}" }.join("\n")}",
        section("Removed", removed.map { |locode| "`#{locode}` #{@before[locode][:name]}" }, limit: nil),
        section("Added", added.map { |locode| "`#{locode}` #{@after[locode][:name]}" }),
        section("Renamed", renamed.map { |locode, was, now| "`#{locode}` #{was} → #{now}" }),
        section("Names", renamed_alternates.map { |locode, name, gained, dropped| names_line(locode, name, gained, dropped) }),
        by_source_line,
        section("Coordinates", repositioned.map { |locode, name, kind| "`#{locode}` #{name} — #{POSITION_WORDS.fetch(kind)}" }),
        section("Subdivision", resubdivided.map { |locode, name, was, now| "`#{locode}` #{name}: #{path_words(was)} → #{path_words(now)}" })
      ].compact.join("\n\n")
    end

    POSITION_WORDS = {
      located: "position published for the first time",
      unlocated: "position withdrawn",
      moved: "position moved"
    }.freeze

    # The one-line version, for a changelog entry that should not carry four
    # hundred bullet points.
    def headline
      "#{@after.size} sea ports (#{@before.size} before): " \
        "#{added.size} added, #{removed.size} removed, " \
        "#{renamed.size} renamed, #{repositioned.size} repositioned, " \
        "#{resubdivided.size} with a new subdivision (#{reassigned.size} moved to another principal one)."
    end

    # A real refresh moves a handful of ports between regions, when UNECE
    # corrects an entry or ISO redraws a country. Moving more than this share
    # of the placed ports at once means a source reshuffled its codes.
    MAXIMUM_REASSIGNMENT = 0.02

    # How many ports each source gained, lost or moved a position for, so a
    # reviewer sees which source a coordinate change came from.
    def by_source_line
      return nil if repositioned.empty?

      counts = repositioned.each_with_object(Hash.new { |hash, key| hash[key] = Hash.new(0) }) do |(locode, _, kind), tally|
        source = (kind == :unlocated ? @before : @after)[locode][:source].to_s
        tally[source.empty? ? "unknown" : source][kind] += 1
      end
      lines = counts.sort.map do |source, kinds|
        "#{source}: " + kinds.sort.map { |kind, n| "#{n} #{kind}" }.join(", ")
      end
      "**Coordinates by source**\n\n#{lines.map { |line| "- #{line}" }.join("\n")}"
    end

    private

    def positions_failure
      placed = @before.count { |_, port| port[:point] }
      return nil if placed.zero?

      lost = common.count { |locode| @before[locode][:point] && @after[locode][:point].nil? }
      lost += removed.count { |locode| @before[locode][:point] }
      return nil if lost.to_f / placed <= MAXIMUM_LOST_POSITIONS

      "#{lost} of #{placed} positioned ports lost their position, past the #{(MAXIMUM_LOST_POSITIONS * 100).round}% limit: " \
        "a coordinate source disappeared."
    end

    def moved_failure
      placed = @before.count { |_, port| port[:point] }
      return nil if placed.zero?

      far = common.count do |locode|
        was = @before[locode][:point]
        now = @after[locode][:point]
        was && now && CoordinateSources.km(was, now) > MOVED_KM
      end
      return nil if far.to_f / placed <= MAXIMUM_MOVED

      "#{far} of #{placed} positions moved over #{MOVED_KM} km, past the #{(MAXIMUM_MOVED * 100).round}% limit: a source reshuffled its coordinates."
    end

    def names_line(locode, name, gained, dropped)
      changes = gained.map { |each| "+#{each}" } + dropped.map { |each| "−#{each}" }
      "`#{locode}` #{name}: #{changes.join(', ')}"
    end

    def path_words(path)
      path.empty? ? "none" : path.split.join(" › ")
    end

    def reassignment_failure
      placed = regioned_count(@before)
      return nil if placed.zero?

      share = reassigned.size.to_f / placed
      return nil if share <= MAXIMUM_REASSIGNMENT

      "#{reassigned.size} ports moved to another principal subdivision, past the #{(MAXIMUM_REASSIGNMENT * 100).round}% limit: " \
        "a source reshuffled its codes."
    end

    def common
      @common ||= (@before.keys & @after.keys).sort
    end

    def count_failure
      return nil if @after.size >= MINIMUM_COUNT

      "Only #{@after.size} ports in the rebuilt table, below the floor of #{MINIMUM_COUNT}."
    end

    def shrinkage_failure
      return nil if @before.empty?

      shrinkage = (@before.size - @after.size).to_f / @before.size
      return nil if shrinkage <= MAXIMUM_SHRINKAGE

      "The table shrank by #{(shrinkage * 100).round(1)}%, past the #{(MAXIMUM_SHRINKAGE * 100).round}% limit."
    end

    # Losing subdivisions in bulk means the ISO 3166-2 list failed to load or
    # UNECE dropped the column, not that ports moved country. A table that
    # had none before (every table before this column existed) has nothing
    # to lose.
    def region_failure
      was = regioned_count(@before)
      return nil if was.zero?

      now = regioned_count(@after)
      shrinkage = (was - now).to_f / was
      return nil if shrinkage <= MAXIMUM_SHRINKAGE

      "Ports with a principal subdivision fell from #{was} to #{now}, past the #{(MAXIMUM_SHRINKAGE * 100).round}% limit."
    end

    def regioned_count(ports)
      ports.count { |_, port| !port[:path].to_s.empty? }
    end

    def anchor_failures
      ANCHORS.reject { |locode| @after.key?(locode) }
        .map { |locode| "`#{locode}` is gone, and a port that large does not disappear." }
    end

    def excluded_failures
      EXCLUDED.select { |locode| @after.key?(locode) }
        .map { |locode| "`#{locode}` is now classified as a sea port upstream, which is a decision to make deliberately." }
    end

    # Removals are listed in full — they are the changes that break a caller.
    # Everything else is capped, because a release that adds four hundred ports
    # should not bury the four that were taken away.
    def section(title, lines, limit: 40)
      return nil if lines.empty?

      shown = limit.nil? ? lines : lines.first(limit)
      body = shown.map { |line| "- #{line}" }.join("\n")
      body += "\n- …and #{lines.size - shown.size} more" if lines.size > shown.size
      "**#{title}** (#{lines.size})\n\n#{body}"
    end
  end
end
