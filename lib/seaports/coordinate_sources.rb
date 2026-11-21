# frozen_string_literal: true

require "csv"

require_relative "../seaports"

module Seaports
  # Turns a list of candidate positions from an open dataset (the NGA World Port
  # Index, Wikidata) into the reviewed file that Seaports::Builder merges.
  #
  # A candidate is only worth a row when it can change the table: the port is
  # one we ship, UN/LOCODE publishes no position for it (the table says so in
  # its coordinate_source column, written by the builder), and nothing that
  # outranks this source (a hand-placed override, a better dataset) has one.
  # Everything else is dropped here and counted, so the file holds exactly the
  # ports the source fills, and a row leaves it on the next regeneration once
  # UN/LOCODE catches up.
  #
  # The precedence itself lives in Builder#coordinates_for: UN/LOCODE, then the
  # hand-written file, then the World Port Index, then Wikidata.
  module CoordinateSources
    HEADERS = %w[locode name lat lng source].freeze

    # Further than this from its own country's border, a position is somebody's
    # typo or a code that means something else, and is not used.
    COUNTRY_KM = 50

    Candidate = Data.define(:locode, :name, :lat, :lng, :source)
    # +mismatches+: [locode, the dataset's name, the table's name] for the kept
    # rows where the two names share nothing, which usually means the dataset
    # files another place under that code.
    Result = Data.define(:rows, :counts, :mismatches)

    # +candidates+ are Candidates with raw values: a locode as written and
    # a lat and lng as numbers or strings.
    #
    # +table+ is { locode => [name, lat, lng, coordinate_source] } as shipped
    # (see CoordinateSources.table); +held+ the locodes a higher-ranked source
    # places. A port is open to this source when it has no position, or when
    # its position is not UN/LOCODE's own. +boundaries+ is optional: without it
    # nothing is checked against a country; a country the map cannot judge
    # passes and is counted as unjudged.
    def self.select(candidates, table:, held: [], boundaries: nil)
      counts = Hash.new(0)
      valid = candidates.filter_map do |candidate|
        counts[:candidates] += 1
        locode = candidate.locode.to_s.delete(" ").upcase
        lat = Float(candidate.lat.to_s.strip, exception: false)
        lng = Float(candidate.lng.to_s.strip, exception: false)
        unless locode.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/) && lat && lng &&
            lat.between?(-90, 90) && lng.between?(-180, 180) && !(lat.zero? && lng.zero?)
          counts[:invalid] += 1
          next
        end
        candidate.with(locode:, lat: lat.round(4), lng: lng.round(4))
      end

      mismatches = []
      rows = valid.group_by(&:locode).sort.filter_map do |locode, group|
        if group.size > 1
          counts[:duplicate] += 1
          next
        end
        candidate = group.first
        name, lat, _lng, source = table[locode]
        reason =
          if name.nil? then :not_in_table
          elsif held.include?(locode) then :held_by_other_source
          elsif !lat.nil? && (source.nil? || source == "unlocode") then :has_unlocode_position
          else
            judged = boundaries&.near_country?(locode[0, 2], candidate.lat, candidate.lng, COUNTRY_KM)
            counts[:unjudged] += 1 if boundaries && judged.nil?
            judged == false ? :off_country : :kept
          end
        counts[reason] += 1
        next unless reason == :kept

        mismatches << [locode, candidate.name, name] if candidate.name && !same_place?(candidate.name, name)
        [locode, name, candidate.lat, candidate.lng, candidate.source]
      end
      Result.new(rows:, counts: counts.to_h, mismatches:)
    end

    # Whether two names plausibly name one place: one holds the other once
    # accents, case and punctuation are gone ("Rosslare Europort" holds
    # "Rosslare").
    def self.same_place?(one, other)
      a = fold(one)
      b = fold(other)
      a.empty? || b.empty? || a.include?(b) || b.include?(a)
    end

    LETTERS = { "ø" => "o", "æ" => "ae", "œ" => "oe", "ß" => "ss", "đ" => "d", "ð" => "d", "ł" => "l", "þ" => "th" }.freeze

    def self.fold(name)
      name.to_s.downcase.gsub(/[øæœßđðłþ]/, LETTERS).unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
        .gsub(/\b(saint|sainte|ste)\b/, "st").gsub(/\b(terminal|harbou?r|port)\b/, "").gsub(/[^a-z0-9]/, "")
    end

    # { locode => [name, lat, lng, coordinate_source] } for the shipped table,
    # with nil coordinates for the ports that have none.
    def self.table(path = Seaports::TABLE_PATH)
      CSV.read(path, headers: true).to_h do |row|
        point = row["lat"].to_s.strip.empty? ? [nil, nil] : [row["lat"].to_f, row["lng"].to_f]
        [row["locode"], [row["name"], *point, row["coordinate_source"].to_s.empty? ? nil : row["coordinate_source"]]]
      end
    end

    def self.write(path, rows)
      CSV.open(path, "w") do |csv|
        csv << HEADERS
        rows.sort_by(&:first).each { |row| csv << row }
      end
      path
    end

    # { locode => [lat, lng] } a generated file holds, empty when it does not
    # exist yet.
    def self.points(path)
      return {} unless File.exist?(path)

      CSV.read(path, headers: true).to_h { |row| [row["locode"], [row["lat"].to_f, row["lng"].to_f]] }
    end

    # Great-circle distance in kilometres.
    def self.km(from, to)
      rad = Math::PI / 180
      a = (Math.sin((to[0] - from[0]) * rad / 2)**2) +
        (Math.cos(from[0] * rad) * Math.cos(to[0] * rad) * (Math.sin((to[1] - from[1]) * rad / 2)**2))
      12_742 * Math.asin(Math.sqrt(a))
    end

    # How a regeneration changed a file's positions: the locodes added and
    # removed, and those that moved more than +km+.
    Change = Data.define(:added, :removed, :moved, :before_size)

    def self.change(before, after, km: 1)
      Change.new(added: (after.keys - before.keys).sort, removed: (before.keys - after.keys).sort,
        moved: (before.keys & after.keys).select { |locode| km(before[locode], after[locode]) > km }.sort, before_size: before.size)
    end

    # The one-line account of a regeneration, for the pull request.
    def self.summary(label, change, size, counts)
      skipped = counts.except(:candidates, :kept, :unjudged).map { |reason, n| "#{n} #{reason.to_s.tr('_', ' ')}" }
      unjudged = counts[:unjudged].to_i.positive? ? " #{counts[:unjudged]} kept without a country check (the map does not draw it)." : ""
      "#{label}: #{size} ports placed (#{change.added.size} added, #{change.removed.size} removed, #{change.moved.size} moved over 1 km). " \
        "Of #{counts.fetch(:candidates, 0)} candidates, skipped: #{skipped.empty? ? 'none' : skipped.join(', ')}.#{unjudged}"
    end
  end
end
