# frozen_string_literal: true

require "csv"
require "json"

require_relative "../seaports"

module Seaports
  # Rebuilds the shipped sea-port table from a published UN/LOCODE code list.
  #
  # The table is generated, not hand-maintained, and this is the only thing
  # that should ever write it — so a refresh is `rake seaports:refresh` against
  # a newer UNECE release rather than a diff someone edits by hand.
  #
  # UNECE's own distribution is a zip of headerless latin-1 CSVs, so the source
  # here is the datasets/un-locode mirror, which republishes the same list with
  # headers, UTF-8 and a machine-readable release number. It is a third party,
  # which is why every refresh runs through Seaports::Diff before anything
  # ships.
  #
  # Nothing breaks if a release is skipped: a port missing from our copy falls
  # back to whatever the caller rendered before the table existed.
  class Builder
    SOURCE_URL = "https://raw.githubusercontent.com/datasets/un-locode/main/data/code-list.csv"
    DATAPACKAGE_URL = "https://raw.githubusercontent.com/datasets/un-locode/main/datapackage.json"

    HEADERS = %w[locode name lat lng subdivision principal_subdivision subdivision_source].freeze

    # Reviewed subdivisions for ports UN/LOCODE gives none and no position to
    # place on a map: Valencia, Algeciras, Barcelona. Kept outside data/*.csv
    # so it is not shipped in the gem; only its result is.
    OVERRIDES_PATH = File.expand_path("../../data/sources/subdivision_overrides.csv", __dir__)

    # The published list, straight off the network — or off disk, if what was
    # handed over is a path. Both, because a rebuild from an already-downloaded
    # release is how this is debugged, and it should not need a different
    # entry point. Kept separate from parsing so every other path through this
    # class can be tested with a string.
    def self.fetch(source = SOURCE_URL)
      return File.read(source) if File.exist?(source)

      require "open-uri"
      URI.parse(source).read
    end

    # Which UN/LOCODE edition the mirror is currently publishing, as UNECE
    # names it: "2024.2.0" upstream becomes "2024-2" here. Nil rather than a
    # guess if the mirror changes shape — a wrong release number is worse than
    # an absent one, because it would be believed.
    def self.published_release(source = DATAPACKAGE_URL)
      version = JSON.parse(fetch(source))["version"].to_s
      match = version.match(/\A(\d{4})\.(\d)/)
      match && "#{match[1]}-#{match[2]}"
    rescue StandardError
      nil
    end

    # Reads OVERRIDES_PATH (or +path+) into { locode => ISO 3166-2 code }.
    def self.overrides(path = OVERRIDES_PATH)
      return {} unless File.exist?(path)

      CSV.foreach(path, headers: true).to_h { |row| [row["locode"].strip.upcase, row["subdivision"].strip.upcase] }
    end

    # Where a port's subdivision comes from, best first:
    #
    # - +overrides+, { locode => code }, reviewed by a person;
    # - UN/LOCODE's own subdivision column;
    # - +boundaries+ (Seaports::Boundaries), the subdivision the port's
    #   coordinates fall in.
    #
    # Every code is checked against +subdivisions+, the ISO 3166-2 list (see
    # Seaports::Subdivisions), which also gives the principal subdivision
    # above it. Without that list the subdivision columns stay empty, which
    # keeps a test about something else from needing it.
    def initialize(source, subdivisions: nil, boundaries: nil, overrides: {})
      @source = source
      @subdivisions = subdivisions
      @boundaries = boundaries
      @overrides = overrides
    end

    # [locode, name, lat, lng, subdivision, principal_subdivision,
    # subdivision_source] per port, deduplicated and sorted by locode.
    # Sorted because the file is committed: a stable order means a refresh
    # diff shows what changed rather than the whole table moving.
    def rows
      @rows ||= CSV.parse(@source, headers: true)
        .select { |row| seaport?(row) }
        .map { |row| port_row(row) }
        .uniq { |locode, *| locode }
        .sort_by(&:first)
    end

    def write(path = Seaports::TABLE_PATH)
      CSV.open(path, "w") do |csv|
        csv << HEADERS
        rows.each { |row| csv << row }
      end
      path
    end

    def located_count
      rows.count { |row| !row[2].nil? }
    end

    def subdivided_count
      rows.count { |row| !row[5].nil? }
    end

    private

    # UNECE classifies every entry by function, and position 1 of that string
    # is "port" — the only one a vessel can call at. Keeping the other 98k
    # entries would mean a road terminal or a postal exchange could answer a
    # lookup for a ship's port call, which is worse than not answering at all.
    #
    # `Change` marks an entry's fate in the current release; "X" is one being
    # removed, and those are dropped.
    def seaport?(row)
      row["Function"].to_s.include?("1") &&
        !row["Change"].to_s.include?("X") &&
        !row["Location"].to_s.strip.empty? &&
        !row["Name"].to_s.strip.empty?
    end

    def port_row(row)
      locode = "#{row['Country']}#{row['Location']}".upcase
      lat, lng = decimal_degrees(row["Coordinates"])
      subdivision, source = subdivision_for(locode, row, lat, lng)
      [locode, row["Name"].strip, lat, lng, subdivision, @subdivisions&.principal(subdivision), source]
    end

    # [code, source], or [nil, nil] when no source has a valid one.
    def subdivision_for(locode, row, lat, lng)
      return [nil, nil] if @subdivisions.nil?

      country = row["Country"].to_s.strip.upcase
      if (override = @overrides[locode])
        code = @subdivisions.code(country, override.delete_prefix("#{country}-"))
        raise ArgumentError, "#{locode}: override #{override} is not an ISO 3166-2 code of #{country}" if code.nil?

        return [code, "override"]
      end

      code = @subdivisions.code(country, row["Subdivision"])
      return [code, "unlocode"] if code

      mapped = (@boundaries&.codes_at(country, lat, lng) || []).lazy
        .filter_map { |candidate| @subdivisions.code(country, candidate.delete_prefix("#{country}-")) }.first
      mapped ? [mapped, "boundaries"] : [nil, nil]
    end

    # UNECE writes coordinates as "2421N 11812E" — degrees and whole minutes,
    # zero-padded, no separator. Rounded to four places, which is metres: the
    # source only resolves to a minute (about a mile), and writing more digits
    # than that would dress a coarse figure up as a survey.
    def decimal_degrees(value)
      match = value.to_s.strip.match(/\A(\d{2})(\d{2})([NS])\s+(\d{3})(\d{2})([EW])\z/)
      return [nil, nil] if match.nil?

      lat = (match[1].to_i + (match[2].to_i / 60.0)) * (match[3] == "S" ? -1 : 1)
      lng = (match[4].to_i + (match[5].to_i / 60.0)) * (match[6] == "W" ? -1 : 1)
      [lat.round(4), lng.round(4)]
    end
  end
end
