# frozen_string_literal: true

require "json"

module Seaports
  # ISO 3166-2, for turning UN/LOCODE's subdivision column into codes other
  # datasets share.
  #
  # UN/LOCODE files Hamburg under "HH" and Felixstowe under "SFK". Read with
  # the country in front, both are ISO 3166-2 codes, but at different levels:
  # DE-HH is a German state, GB-SFK an English county. Public holiday
  # calendars, address geocoders and most other datasets that split a country
  # work at the top level, the principal subdivision: DE-HH, and GB-ENG for
  # Felixstowe. ISO publishes which code sits inside which, so the climb from
  # county to nation is a lookup, not a guess.
  #
  # Build-time only. The source is Debian's iso-codes, the ISO 3166-2 list
  # most Linux systems ship, and nothing at runtime reads it: the resolved
  # codes are written into the table.
  class Subdivisions
    SOURCE_URL = "https://salsa.debian.org/iso-codes-team/iso-codes/-/raw/main/data/iso_3166-2.json"

    # A chain longer than this is a loop in the data, not a real hierarchy:
    # ISO goes three levels deep at most.
    MAX_DEPTH = 5

    def self.parse(json)
      new(JSON.parse(json).fetch("3166-2"))
    end

    def initialize(entries)
      @parents = entries.to_h { |entry| [entry.fetch("code"), entry["parent"]] }
    end

    # "DE-HH" for ("DE", "HH"), or nil when the pair is not an ISO 3166-2
    # code. UN/LOCODE carries a few codes ISO has retired or never had, and a
    # code nobody else recognises is worse than none.
    def code(country, subdivision)
      return nil if subdivision.to_s.strip.empty?

      candidate = "#{country.to_s.strip.upcase}-#{subdivision.to_s.strip.upcase}"
      @parents.key?(candidate) ? candidate : nil
    end

    # +code+ and every subdivision above it, most specific first:
    # ["FR-67", "FR-6AE", "FR-GES"] for Bas-Rhin, ["DE-HH"] for Hamburg.
    #
    # The whole chain rather than just its top, because ISO's top level is not
    # always the one that matters. Alsace-Moselle (FR-6AE) has holidays the
    # rest of Grand Est (FR-GES) does not, and Indonesia's top level is island
    # groups, above the provinces that run anything. A caller matches on
    # whichever level its own data uses.
    #
    # Empty for nil, and for a chain that breaks (a parent the list does not
    # hold) or loops: a guessed top would be believed.
    def path(code)
      return [] if code.nil?

      chain = [code]
      MAX_DEPTH.times do
        parent = @parents[chain.last]
        return chain if parent.nil?
        return [] unless @parents.key?(parent)

        chain << parent
      end
      []
    end

    # The top of +code+'s path: GB-ENG for GB-SFK, ES-VC for ES-V, DE-HH for
    # DE-HH itself. Nil when the path is empty.
    def principal(code)
      path(code).last
    end

    def size
      @parents.size
    end
  end
end
