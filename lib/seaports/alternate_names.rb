# frozen_string_literal: true

require "csv"
require "set"

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
  # 3. the name in the parentheses of a UN/LOCODE name, "El Iskandariya
  #    (Alexandria)", for a port with a position, when the parenthesis holds
  #    one plain name.
  #
  # None of them is checked against the place itself, so an alternate is a
  # name that port is called by in some source, not a guarantee. What is done
  # about it:
  #
  # - a name that is another port's own name in the same country is dropped
  #   (a main name always beats an alternate), and so is a name that two or
  #   more ports of a country share as alternates ("Bruxelles" on three ports);
  # - the World Port Index's junk is filtered (company, terminal and vessel
  #   names, country names, fragments), and a reviewed file,
  #   data/sources/alternate_names_rejected.csv, drops the wrong-place names
  #   that got past the filter;
  # - a parenthesis is read only when it is one name of at least four
  #   characters, and not a former name, a facility or a list.
  #
  # The shipped table keeps them in its last column, separated by "|".
  module AlternateNames
    HEADERS = %w[locode name source].freeze
    SEPARATOR = "|"
    LOCODE = /\A[A-Z]{2}[A-Z0-9]{3}\z/
    PARENTHESIZED = /\(([^()]+)\)/
    MINIMUM_LENGTH = 4
    # What a parenthesis says when it is not another name for the place: a
    # former name, a kind of facility, a zone or a base.
    NOT_A_NAME = /\b(?:ex|ports?|sts|icad|anchorage|facility|terminals?|term|tandem load|ferry port|zone franche|afb|esb|loop|oil)\b/i
    # Names in the World Port Index's column that are not the place: vessels,
    # terminals, bases and companies ("AS" as a suffix, a Norwegian company
    # form), and the Estonian "sadamate" (ports).
    JUNK = [/\A(?:fso|fpso|fspo|mv)\b/i, /\b(?:terminal|term|base|oil|naval|sadamate|petroleum)\b/i, /\bAS\z/].freeze

    # A name for comparing: lower case, without accents, punctuation or
    # repeated spaces. Two spellings with the same key are one name.
    def self.key(name)
      name.to_s.downcase.gsub(/[øæœßđðłþ]/, "ø" => "o", "æ" => "ae", "œ" => "oe", "ß" => "ss", "đ" => "d", "ð" => "d", "ł" => "l", "þ" => "th")
        .unicode_normalize(:nfd).gsub(/\p{Mn}/, "").gsub(/[^a-z0-9]+/, " ").strip
    end

    # A parenthesis that is one plain name: no list, at least four characters,
    # nothing that describes the place instead of naming it.
    def self.parenthesis_name?(text)
      text.length >= MINIMUM_LENGTH && !text.match?(%r{[/,;]}) && !text.match?(NOT_A_NAME)
    end

    # The candidate alternate names of a port, before they are compared with
    # other ports (see resolve): +layers+ is a list of { locode => [names] },
    # best first, then the parenthesized name. Deduplicated by key, without any
    # name equal to the port's own (whole, or outside its parentheses) and
    # without the names +rejected+ ({ locode => [names] }) lists for it.
    def self.for(locode:, name:, located:, layers: [], rejected: {})
      own = [name, name.to_s.sub(PARENTHESIZED, "")].map { |spelling| key(spelling) }
      refused = rejected.fetch(locode, []).map { |spelling| key(spelling) }
      parenthesized = located ? name.to_s.scan(PARENTHESIZED).flatten.map(&:strip).select { |text| parenthesis_name?(text) } : []
      candidates = layers.flat_map { |layer| layer.fetch(locode, []) } + parenthesized
      candidates.map { |candidate| candidate.to_s.delete(SEPARATOR).strip }
        .reject { |candidate| key(candidate).empty? || own.include?(key(candidate)) || refused.include?(key(candidate)) }
        .uniq { |candidate| key(candidate) }
    end

    # { locode => names } for +ports+, [[locode, name, candidates]], once each
    # candidate has been compared with the rest of its country: dropped when it
    # is another port's own name, or when two or more ports of the country
    # carry it. A main name always beats an alternate, and a name that fits
    # several ports names none of them.
    def self.resolve(ports)
      ports.group_by { |locode, _, _| locode[0, 2] }.each_value.with_object({}) do |country, resolved|
        mains = country.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(locode, name, _), index|
          main_spellings(name).each { |spelling| index[spelling] << locode }
        end
        kept = country.to_h do |locode, _, candidates|
          [locode, candidates.reject { |candidate| mains.key?(key(candidate)) }]
        end
        shared = kept.values.flat_map { |names| names.map { |name| key(name) }.uniq }.tally.select { |_, n| n > 1 }.keys
        kept.each { |locode, names| resolved[locode] = names.reject { |name| shared.include?(key(name)) } }
      end
    end

    # Every comparable spelling of a port's own name, for the comparison in
    # resolve: the whole, outside its parentheses, each part split on "/" and
    # ",", and each of those without a trailing Pt, Port or Harbour/Harbor
    # ("Jingtang Pt" is also "Jingtang", "Ibiza/Eivissa" is also "Eivissa").
    # An alternate that is any of them names a port already.
    def self.main_spellings(name)
      wholes = [name.to_s, name.to_s.sub(PARENTHESIZED, "")]
      parts = wholes.flat_map { |whole| [whole] + whole.split(%r{[/,]}) }
      keys = parts.map { |part| key(part) }.reject(&:empty?)
      (keys + keys.map { |each| each.sub(/ (?:pt|port|harbou?r)\z/, "") }).reject(&:empty?).uniq
    end

    # The table cell for +names+.
    def self.dump(names)
      names.empty? ? nil : names.join(SEPARATOR)
    end

    # { locode => [names] } from a file of locode, name, source rows, in file
    # order. A person types the hand-written one, so a malformed locode, a
    # blank name or source, or the same name twice for a port stops the build
    # with the line to fix. +third+ is the name of the third column: "source",
    # or "reason" for the rejected names.
    def self.read(path, third: "source")
      return {} unless File.exist?(path)

      CSV.foreach(path, headers: true).with_index(2).each_with_object({}) do |(row, line), names|
        locode = row["locode"].to_s.strip.upcase
        name = row["name"].to_s.strip
        raise ArgumentError, "#{path}:#{line}: #{locode.inspect} is not a locode" unless locode.match?(LOCODE)
        raise ArgumentError, "#{path}:#{line}: #{locode} has no name" if name.empty?
        raise ArgumentError, "#{path}:#{line}: #{locode} #{name.inspect} has no #{third}" if row[third].to_s.strip.empty?
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

    # The names the index's column may give a port, before any comparison:
    # split on ";" and ",", and without junk, a country name (+countries+ is a
    # set of keys) or a fragment of fewer than four characters.
    def self.index_names(cell, countries: Set.new)
      cell.to_s.split(/[;,]/).map(&:strip).reject do |name|
        name.length < MINIMUM_LENGTH || JUNK.any? { |pattern| name.match?(pattern) } || countries.include?(key(name))
      end
    end

    # Rows for the generated World Port Index file. +candidates+ is
    # [[locode, "Antwerp; Anvers"]] as the index writes them, +ports+ the
    # locodes of the table. Dropped, and counted: a locode not in the table,
    # and a locode on several index rows, which names no one port. Same
    # guards as the coordinate import. Returns [rows, counts].
    def self.select(candidates, ports:, source:, countries: Set.new)
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
        names = index_names(group.first.last, countries:).uniq { |name| key(name) }
        counts[:ports] += 1 unless names.empty?
        names.map { |name| [locode, name, source] }
      end
      [rows, counts.to_h]
    end
  end
end
