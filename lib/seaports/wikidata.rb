# frozen_string_literal: true

require "json"
require "uri"

require_relative "coordinate_sources"
require_relative "http"

module Seaports
  # Positions from Wikidata (CC0): every item with a UN/LOCODE (P1937) and
  # coordinates (P625), about 43,000 codes. Used only for ports that UN/LOCODE,
  # the hand-written file and the World Port Index all leave without one.
  #
  # Wikidata is crowd-edited, and a UN/LOCODE can sit on several items (a port,
  # its town, a terminal), so a code is resolved before it is used:
  #
  # - only items typed as a port (Q44782) or harbour (Q283202), or a subclass
  #   of either, are used. A town item is a city centre, often inland, and
  #   nothing in the build can tell a coastal one from an inland one cheaply,
  #   so a code with no port-typed item is left out and counted;
  # - one port item is taken;
  # - several are taken only when they all lie within CLUSTER_KM of each other,
  #   and then the one nearest their centroid is; otherwise the code is skipped;
  # - if the same code is also on a town item, the port item must lie within
  #   TOWN_KM of one of them, or the code is ambiguous and skipped.
  #
  # The country check in CoordinateSources.select catches the rest.
  class Wikidata
    ENDPOINT = "https://query.wikidata.org/sparql"
    PROVENANCE_PATH = File.expand_path("../../data/sources/wikidata_provenance.json", __dir__)
    CLUSTER_KM = 10
    TOWN_KM = 50
    # About how many codes Wikidata resolves to a position (43,565 in November
    # 2026). A result below MINIMUM_SHARE of it is an outage or a broken query.
    EXPECTED_CODES = 40_000
    # Below this share of the file it replaces, a result is an outage or a
    # broken query, not Wikidata losing codes, and is refused.
    MINIMUM_SHARE = 0.8

    NUMBER = /[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/
    POINT = /\APoint\(\s*(#{NUMBER})\s+(#{NUMBER})\s*\)\z/

    Hit = Data.define(:item, :locode, :lat, :lng, :port)

    def self.query(prefix)
      <<~SPARQL
        SELECT ?item ?locode ?coord ?port WHERE {
          ?item wdt:P1937 ?locode .
          FILTER(STRSTARTS(?locode, "#{prefix}"))
          ?item wdt:P625 ?coord .
          BIND(EXISTS { ?item wdt:P31/wdt:P279* ?type . VALUES ?type { wd:Q44782 wd:Q283202 } } AS ?port)
        }
      SPARQL
    end

    # One query per first letter of the code, and when Wikidata's 60 second
    # limit cuts one off, its 26 two-letter children instead: the split that
    # a single country's worth of codes always fits in.
    def self.fetch_hits(http: Http.method(:get), letters: ("A".."Z").to_a, retries: 1)
      letters.flat_map { |letter| fetch_prefix(letter, http, retries) }
    end

    def self.fetch_prefix(prefix, http, retries)
      body = request(prefix, http, retries)
      return parse(body) if body

      raise "Wikidata would not answer for #{prefix}" if prefix.size > 1

      ("A".."Z").flat_map { |second| fetch_prefix("#{prefix}#{second}", http, retries) }
    end

    # The answer's body, or nil when it would not come after +retries+ more
    # tries: a status that is not 200, a 200 whose JSON is cut off, or a
    # network error. A 429 waits as long as Wikidata's Retry-After says.
    def self.request(prefix, http, retries)
      url = "#{ENDPOINT}?#{URI.encode_www_form(query: query(prefix), format: 'json')}"
      (retries + 1).times do
        status, body, headers = http.call(url, "Accept" => "application/sparql-results+json")
        if status == 200
          return body if JSON.parse(body).dig("results", "bindings").is_a?(Array)
        end

        sleep(wait(status, headers)) if status == 429 || status >= 500
      rescue StandardError
        sleep(5)
      end
      nil
    end

    def self.wait(status, headers)
      seconds = status == 429 ? Integer(headers&.fetch("retry-after", nil).to_s, exception: false) : nil
      (seconds || 5).clamp(1, 120)
    end

    def self.parse(body)
      JSON.parse(body).dig("results", "bindings").filter_map do |binding|
        point = binding.dig("coord", "value").to_s.match(POINT)
        next unless point

        Hit.new(item: binding.dig("item", "value").to_s.split("/").last, locode: binding.dig("locode", "value").to_s.delete(" ").upcase,
          lat: point[2].to_f, lng: point[1].to_f, port: binding.dig("port", "value").to_s == "true")
      end
    end

    # One Candidate per code, by the rules above, and { ambiguous:,
    # not_port_typed: } for the codes left out: those with no port-typed item,
    # and those whose items cannot be told apart.
    def self.candidates(hits)
      stats = { ambiguous: 0, not_port_typed: 0 }
      candidates = hits.group_by(&:locode).filter_map do |locode, group|
        group = group.uniq { |hit| [hit.item, hit.lat, hit.lng] }
        ports = group.select(&:port)
        if ports.empty?
          stats[:not_port_typed] += 1
          next
        end
        pick = resolve(ports, group - ports)
        stats[:ambiguous] += 1 if pick.nil?
        next unless pick

        CoordinateSources::Candidate.new(locode:, name: nil, lat: pick.lat, lng: pick.lng, source: "Wikidata #{pick.item} (port, CC0)")
      end
      [candidates, stats]
    end

    def self.resolve(ports, towns)
      pick =
        if ports.size == 1
          ports.first
        elsif ports.combination(2).all? { |a, b| km(a.lat, a.lng, b.lat, b.lng) <= CLUSTER_KM }
          centre = [ports.sum(&:lat) / ports.size, ports.sum(&:lng) / ports.size]
          ports.min_by { |hit| km(hit.lat, hit.lng, *centre) }
        end
      return nil unless pick
      return pick if towns.empty? || towns.any? { |town| km(pick.lat, pick.lng, town.lat, town.lng) <= TOWN_KM }

      nil
    end

    # Great-circle distance, to a kilometre.
    def self.km(lat1, lng1, lat2, lng2)
      rad = Math::PI / 180
      a = (Math.sin((lat2 - lat1) * rad / 2)**2) +
        (Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin((lng2 - lng1) * rad / 2)**2))
      12_742 * Math.asin(Math.sqrt(a))
    end
  end
end
