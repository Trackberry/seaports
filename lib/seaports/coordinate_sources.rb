# frozen_string_literal: true

require "csv"

require_relative "../seaports"

module Seaports
  # Turns a list of candidate positions from an open dataset (the NGA World Port
  # Index, Wikidata) into the reviewed file that Seaports::Builder merges.
  #
  # A candidate is only worth a row when it can change the table: the port is
  # one we ship, UN/LOCODE publishes no position for it, and nothing that
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
    Result = Data.define(:rows, :counts)

    # +candidates+ are Candidates with raw values: a locode as written and
    # a lat and lng as numbers or strings.
    #
    # +table+ is { locode => [name, lat, lng] } as shipped; +held+ the locodes
    # a higher-ranked source places; +supplied+ { locode => [lat, lng] }, every
    # position the builder currently fills from a supplementary file, which is
    # how a port the table shows as placed is told apart from one UN/LOCODE
    # placed itself. +boundaries+ is optional: without it nothing is checked
    # against a country.
    def self.select(candidates, table:, held: [], supplied: {}, boundaries: nil)
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

      by_locode = valid.group_by(&:locode)
      rows = by_locode.sort.filter_map do |locode, group|
        if group.size > 1
          counts[:duplicate] += 1
          next
        end
        candidate = group.first
        name, lat, lng = table[locode]
        reason =
          if name.nil? then :not_in_table
          elsif held.include?(locode) then :held_by_other_source
          elsif !lat.nil? && [lat, lng] != supplied[locode] then :has_unlocode_position
          elsif boundaries && boundaries.near_country?(locode[0, 2], candidate.lat, candidate.lng, COUNTRY_KM) == false then :off_country
          else :kept
          end
        counts[reason] += 1
        [locode, name, candidate.lat, candidate.lng, candidate.source] if reason == :kept
      end
      Result.new(rows:, counts: counts.to_h)
    end

    # { locode => [name, lat, lng] } for the shipped table, with nil for the
    # ports that have no position.
    def self.table(path = Seaports::TABLE_PATH)
      CSV.read(path, headers: true).to_h do |row|
        point = row["lat"].to_s.strip.empty? ? [nil, nil] : [row["lat"].to_f, row["lng"].to_f]
        [row["locode"], [row["name"], *point]]
      end
    end

    def self.write(path, rows)
      CSV.open(path, "w") do |csv|
        csv << HEADERS
        rows.sort_by(&:first).each { |row| csv << row }
      end
      path
    end

    # [locode, ...] a file holds, empty when it does not exist yet.
    def self.locodes(path)
      File.exist?(path) ? CSV.read(path, headers: true).map { |row| row["locode"] } : []
    end

    # The one-line account of a regeneration, for the pull request.
    def self.summary(label, before, after, counts)
      added = after - before
      removed = before - after
      skipped = counts.except(:candidates, :kept).map { |reason, n| "#{n} #{reason.to_s.tr('_', ' ')}" }
      "#{label}: #{after.size} ports placed (#{added.size} added, #{removed.size} removed). " \
        "Of #{counts.fetch(:candidates, 0)} candidates, skipped: #{skipped.empty? ? 'none' : skipped.join(', ')}."
    end
  end
end
