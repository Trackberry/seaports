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

  Port = Data.define(:locode, :name, :coordinates)

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

        ports[locode] = Port.new(locode: locode, name: row["name"], coordinates: point(row))
      end
    end

    def point(row)
      return nil if blank?(row["lat"]) || blank?(row["lng"])

      { "lat" => row["lat"].to_f, "lng" => row["lng"].to_f }
    end

    def blank?(value)
      value.to_s.strip.empty?
    end
  end
end
