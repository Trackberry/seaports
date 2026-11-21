# frozen_string_literal: true

require "csv"

module Seaports
  # The other names a port is called by: "Antwerp" and "Anvers" for BEANR,
  # whose UN/LOCODE name is the Flemish "Antwerpen". A document names a port the
  # way its author does, often in English, so the name alone finds too few.
  #
  # Three sources, best first, merged by AlternateNames.for:
  #
  # 1. data/sources/alternate_names.csv, reviewed by a person (locode, name,
  #    source);
  # 2. the World Port Index's "Alternate Port Name" column, regenerated into
  #    data/sources/alternate_names_wpi.csv by `rake seaports:refresh_wpi`;
  # 3. the English name in the parentheses of a UN/LOCODE name, "El Iskandariya
  #    (Alexandria)", but only for a port with a position: a parenthesis can as
  #    well name the place a minor port is near (RUARM "Arman (Magadan)").
  #
  # The shipped table keeps them in its last column, separated by "|".
  module AlternateNames
    HEADERS = %w[locode name source].freeze
    SEPARATOR = "|"
    LOCODE = /\A[A-Z]{2}[A-Z0-9]{3}\z/
    PARENTHESIZED = /\(([^()]+)\)/
    # A parenthesis that is not another name for the place: a former name, or
    # what kind of facility it is.
    NOT_A_NAME = /\A(?:ex\s|(?:oil\s+(?:terminal|facility)|sts|icad|terminal|anchorage)\b)/i

    # A name for comparing: lower case, without accents, punctuation or
    # repeated spaces. Two spellings with the same key are one name.
    def self.key(name)
      name.to_s.downcase.gsub(/[øæœßđðłþ]/, "ø" => "o", "æ" => "ae", "œ" => "oe", "ß" => "ss", "đ" => "d", "ð" => "d", "ł" => "l", "þ" => "th")
        .unicode_normalize(:nfd).gsub(/\p{Mn}/, "").gsub(/[^a-z0-9]+/, " ").strip
    end

    # The alternate names of a port: +layers+ is a list of { locode => [names] },
    # best first. Deduplicated by key, and without any name equal to the
    # port's own, whole or outside its parentheses.
    def self.for(locode:, name:, located:, layers: [])
      own = [name, name.to_s.sub(PARENTHESIZED, "")].map { |spelling| key(spelling) }
      parenthesized = located ? name.to_s.scan(PARENTHESIZED).flatten.map(&:strip).grep_v(NOT_A_NAME) : []
      candidates = layers.flat_map { |layer| layer.fetch(locode, []) } + parenthesized
      candidates.map { |candidate| candidate.to_s.delete(SEPARATOR).strip }
        .reject { |candidate| key(candidate).empty? || own.include?(key(candidate)) }
        .uniq { |candidate| key(candidate) }
    end

    # The table cell for +names+.
    def self.dump(names)
      names.empty? ? nil : names.join(SEPARATOR)
    end

    # { locode => [names] } from a file of locode, name, source rows, in file
    # order. A person types the hand-written one, so a malformed locode, a
    # blank name or source, or the same name twice for a port stops the build
    # with the line to fix.
    def self.read(path)
      return {} unless File.exist?(path)

      CSV.foreach(path, headers: true).with_index(2).each_with_object({}) do |(row, line), names|
        locode = row["locode"].to_s.strip.upcase
        name = row["name"].to_s.strip
        raise ArgumentError, "#{path}:#{line}: #{locode.inspect} is not a locode" unless locode.match?(LOCODE)
        raise ArgumentError, "#{path}:#{line}: #{locode} has no name" if name.empty?
        raise ArgumentError, "#{path}:#{line}: #{locode} #{name.inspect} has no source" if row["source"].to_s.strip.empty?
        raise ArgumentError, "#{path}:#{line}: #{locode} #{name.inspect} is listed twice" if names[locode]&.any? { |other| key(other) == key(name) }

        (names[locode] ||= []) << name
      end
    end

    # Rows [locode, name, source] for a generated file, sorted.
    def self.write(path, rows)
      CSV.open(path, "w") do |csv|
        csv << HEADERS
        rows.sort_by { |locode, name, _| [locode, key(name)] }.each { |row| csv << row }
      end
      path
    end

    # Rows for the generated World Port Index file. +candidates+ is
    # [[locode, "Antwerp; Anvers"]] as the index writes them, +ports+ the
    # locodes of the table. Dropped, and counted: a locode not in the table,
    # and a locode on several index rows, which names no one port. Same
    # guards as the coordinate import. Returns [rows, counts].
    def self.select(candidates, ports:, source:)
      counts = Hash.new(0)
      rows = candidates.group_by(&:first).sort.flat_map do |locode, group|
        next [] unless locode.match?(LOCODE)

        if group.size > 1
          counts[:duplicate] += 1
          next []
        end
        unless ports.include?(locode)
          counts[:not_in_table] += 1
          next []
        end
        names = group.first.last.to_s.split(";").map(&:strip).reject(&:empty?).uniq { |name| key(name) }
        counts[:ports] += 1 unless names.empty?
        names.map { |name| [locode, name, source] }
      end
      [rows, counts.to_h]
    end
  end
end
