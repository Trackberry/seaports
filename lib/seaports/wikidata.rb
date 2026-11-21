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
  # - items typed as a port (Q44782) or harbour (Q283202), or a subclass of
  #   either, win over the rest;
  # - one candidate left is taken;
  # - several are taken only when they all lie within CLUSTER_KM of each other,
  #   and then the one nearest their centroid is; otherwise the code is skipped.
  #
  # The country check in CoordinateSources.select catches the rest.
  class Wikidata
    ENDPOINT = "https://query.wikidata.org/sparql"
    CLUSTER_KM = 10
    # Below this share of the file it replaces, a result is an outage or a
    # broken query, not Wikidata losing codes, and is refused.
    MINIMUM_SHARE = 0.8

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
    def self.fetch_hits(http: Http.method(:get), letters: ("A".."Z").to_a, retries: 2)
      letters.flat_map { |letter| fetch_prefix(letter, http, retries) }
    end

    def self.fetch_prefix(prefix, http, retries)
      body = request(prefix, http, retries)
      return parse(body) if body

      raise "Wikidata would not answer for #{prefix}" if prefix.size > 1

      ("A".."Z").flat_map { |second| fetch_prefix("#{prefix}#{second}", http, retries) }
    end

    def self.request(prefix, http, retries)
      url = "#{ENDPOINT}?#{URI.encode_www_form(query: query(prefix), format: 'json')}"
      (retries + 1).times do
        status, body = http.call(url, "Accept" => "application/sparql-results+json")
        return body if status == 200

        sleep(5) if status == 429 || status >= 500
      rescue StandardError
        sleep(5)
      end
      nil
    end

    def self.parse(body)
      JSON.parse(body).dig("results", "bindings").filter_map do |binding|
        point = binding.dig("coord", "value").to_s.match(/\APoint\(\s*(-?[\d.]+)\s+(-?[\d.]+)\s*\)\z/)
        next unless point

        Hit.new(item: binding.dig("item", "value").to_s.split("/").last, locode: binding.dig("locode", "value").to_s.delete(" ").upcase,
          lat: point[2].to_f, lng: point[1].to_f, port: binding.dig("port", "value").to_s == "true")
      end
    end

    # One Candidate per code, by the rules above. Codes that cannot be resolved
    # are left out, and counted in the second value.
    def self.candidates(hits)
      ambiguous = 0
      candidates = hits.group_by(&:locode).filter_map do |locode, group|
        pick = resolve(group)
        ambiguous += 1 if pick.nil?
        next unless pick

        CoordinateSources::Candidate.new(locode:, name: nil, lat: pick.lat, lng: pick.lng, source: "Wikidata #{pick.item} (CC0)")
      end
      [candidates, ambiguous]
    end

    def self.resolve(group)
      group = group.uniq { |hit| [hit.item, hit.lat, hit.lng] }
      typed = group.select(&:port)
      group = typed unless typed.empty?
      return group.first if group.size == 1

      centre = [group.sum(&:lat) / group.size, group.sum(&:lng) / group.size]
      return nil unless group.combination(2).all? { |a, b| km(a.lat, a.lng, b.lat, b.lng) <= CLUSTER_KM }

      group.min_by { |hit| km(hit.lat, hit.lng, *centre) }
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
