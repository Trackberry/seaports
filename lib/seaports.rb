# frozen_string_literal: true

require "csv"

require_relative "seaports/version"

# UN/LOCODE sea ports: a locode in, a port name and position out.
#
# Tracking feeds speak in codes. A provider names some port calls and sends
# only a code for others, so a stop that mattered arrives as a bare "XMG" — a
# real, load-bearing fact about a voyage written in a vocabulary nobody reads.
# UNECE publishes the table that turns it back into "Xiamen Pt", and publishes
# coordinates alongside, so one dataset answers both "where is this?" and
# "where do I draw it?".
#
# The table ships inside the gem rather than being fetched: it is reference
# data that changes twice a year, and a port name should not depend on a
# network. `rake seaports:refresh` regenerates it; nothing else should write it.
#
#   Seaports.find("CNXMG")         # => #<data Seaports::Port locode="CNXMG", ...>
#   Seaports.name("AUBNE")         # => "Brisbane"
#   Seaports.coordinates("AUBNE")  # => { "lat" => -27.4667, "lng" => 153.0167 }
#
# Coverage is sea ports only, which is what a vessel's port call is, and
# UNECE's own classification decides what counts. The notable absence is
# PAPCN, "Panama Canal", which some feeds do send: UNECE files it as a road
# terminal with status RL — "recognised location", its weakest, meaning no
# national authority has approved it and its functions were never verified.
# That is the default bucket for an unchecked entry rather than a ruling, but
# the substance holds anyway, because a canal is a waterway and not a port. The
# ports at either end are coded properly (PABLB Balboa, PACTB Cristóbal), so a
# canal transit is better rendered from the country than from a port lookup.
#
# Keeping the filter narrow also guards anyone rebuilding a five-character
# locode from a three-character carrier code, which is a heuristic: a code that
# is not a locode tail could pair with a country to form a valid-looking locode
# for some inland village, and a table of ports is far less likely to name it.
module Seaports
  TABLE_PATH = File.expand_path("../data/un_locode_seaports.csv", __dir__)

  # +subdivision+ is the ISO 3166-2 code of the area the port is in, at
  # whatever level its source chose: "DE-HH" for Hamburg, "GB-SFK" (Suffolk)
  # for Felixstowe. +subdivision_path+ is that code and every ISO subdivision
  # above it, most specific first: ["GB-SFK", "GB-ENG"], or ["FR-67",
  # "FR-6AE", "FR-GES"] for Strasbourg. +principal_subdivision+ is the last of
  # them, ISO's top level.
  #
  # To join a port to other data, match on whichever level of the path that
  # data uses. The top is usually right (German states, UK nations, Spanish
  # communities) but not always. Alsace (FR-6AE, inside Grand Est) and
  # Moselle (FR-57, directly in Grand Est) share two holidays the rest of
  # France does not, so a calendar keys them on those two codes, below the
  # top; ISO has no Alsace-Moselle code. Indonesia's top level is island
  # groups, above its provinces.
  #
  # The code comes from UN/LOCODE where it gives one, from the port's
  # coordinates on Natural Earth's map where it does not, and from a reviewed
  # list for ports neither places (Valencia, Barcelona). Nil, and an empty
  # path, when none of the three does.
  #
  # The three were added in 1.2.0 with defaults, so a Port built from
  # locode, name and coordinates alone, as before, still works.
  Port = Data.define(:locode, :name, :coordinates, :subdivision, :principal_subdivision, :subdivision_path) do
    def initialize(locode:, name:, coordinates:, subdivision: nil, principal_subdivision: nil, subdivision_path: [])
      super
    end
  end

  class << self
    # Nil for anything the table does not hold, which callers must handle:
    # ~17k ports is most of the world's, not all of it, and an unknown code is
    # the ordinary case rather than an error.
    def find(locode)
      key = normalize(locode)
      return nil if key.nil?

      table[key]
    end

    def name(locode)
      find(locode)&.name
    end

    # { "lat" => Float, "lng" => Float }, or nil. String keys because the usual
    # destination is JSON on its way to a map. Roughly a third of the table has
    # no coordinates published, so a named port with no position is normal.
    def coordinates(locode)
      find(locode)&.coordinates
    end

    # "GB-SFK" for Felixstowe, or nil. See Port.
    def subdivision(locode)
      find(locode)&.subdivision
    end

    # "GB-ENG" for Felixstowe, "DE-HH" for Hamburg, or nil. See Port.
    def principal_subdivision(locode)
      find(locode)&.principal_subdivision
    end

    # ["GB-SFK", "GB-ENG"] for Felixstowe, [] for a port nothing places or a
    # code the table does not hold. The codes to hand a holiday calendar that
    # matches on any level: Trackberry::Holidays.holiday?(date, path).
    def subdivision_path(locode)
      find(locode)&.subdivision_path || []
    end

    # Every port in the table, ordered by locode. Materialised on each call
    # rather than handed out from the cache, so a caller cannot mutate the
    # table everyone else reads.
    def all
      table.values.dup
    end

    # How many ports the table holds — the guard that a truncated or
    # half-written CSV is caught by a test rather than by a production page.
    def count
      table.size
    end

    # Which UN/LOCODE edition the shipped table came from, for a caller that
    # wants to assert its data is not years old.
    def data_release
      DATA_RELEASE
    end

    private

    # A locode is five characters: a two-letter country and a three-character
    # place. Anything else is not one, and guessing at it would mean answering
    # a question that was not asked.
    def normalize(locode)
      key = locode.to_s.strip.upcase
      key.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/) ? key : nil
    end

    # Read once, on the first lookup rather than at require time: most
    # processes never look a port up, and the ones that do can afford the parse.
    def table
      @table || LOAD_LOCK.synchronize { @table ||= load_table }
    end

    LOAD_LOCK = Mutex.new

    def load_table
      CSV.foreach(TABLE_PATH, headers: true).each_with_object({}) do |row, ports|
        locode = normalize(row["locode"])
        next if locode.nil? || blank?(row["name"])

        ports[locode] = Port.new(locode: locode, name: row["name"], coordinates: point(row),
          subdivision: presence(row["subdivision"]), principal_subdivision: presence(row["principal_subdivision"]),
          subdivision_path: row["subdivision_path"].to_s.split.freeze)
      end
    end

    def point(row)
      return nil if blank?(row["lat"]) || blank?(row["lng"])

      { "lat" => row["lat"].to_f, "lng" => row["lng"].to_f }
    end

    def blank?(value)
      value.to_s.strip.empty?
    end

    def presence(value)
      blank?(value) ? nil : value.strip
    end
  end
end
