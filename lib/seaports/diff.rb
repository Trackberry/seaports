# frozen_string_literal: true

require "csv"

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

        ports[locode] = { name: row["name"].to_s.strip, point: point(row) }
      end
    end

    def self.point(row)
      lat = row["lat"].to_s.strip
      lng = row["lng"].to_s.strip
      return nil if lat.empty? || lng.empty?

      [lat.to_f, lng.to_f]
    end

    def initialize(before, after)
      @before = before
      @after = after
    end

    def changed?
      !(added.empty? && removed.empty? && renamed.empty? && repositioned.empty?)
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

        [locode, @after[locode][:name], (was.nil? ? :located : (now.nil? ? :unlocated : :moved))]
      end
    end

    # Empty means the refresh may ship. Anything here is a reason it may not,
    # written the way it should read in an issue.
    def failures
      [count_failure, shrinkage_failure, *anchor_failures, *excluded_failures].compact
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
        section("Coordinates", repositioned.map { |locode, name, kind| "`#{locode}` #{name} — #{POSITION_WORDS.fetch(kind)}" })
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
        "#{renamed.size} renamed, #{repositioned.size} repositioned."
    end

    private

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
