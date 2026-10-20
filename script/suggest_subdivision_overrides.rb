# frozen_string_literal: true

# Suggests subdivisions for ports nothing else places, for a person to review
# before they go in data/sources/subdivision_overrides.csv.
#
#   ruby script/suggest_subdivision_overrides.rb candidates.csv > suggestions.csv
#
# candidates.csv has locode and name columns: the ports to look up, usually
# the ones a refresh left without a subdivision in a country where it
# matters. Each is searched by name within its country on OpenStreetMap's
# Nominatim, one request a second as its usage policy asks. The answer's
# ISO 3166-2 codes (county or province first, then region) are written out
# with the place Nominatim matched, so the reviewer can see "Valencia, Comunitat
# Valenciana, España" next to ES-V and judge it. Nothing here writes the
# overrides file: a name search can match the wrong Valencia.

require "csv"
require "json"
require "net/http"
require "uri"

ENDPOINT = URI("https://nominatim.openstreetmap.org/search")
USER_AGENT = "trackberry-seaports-build (+https://github.com/Trackberry/seaports)"

def search(name, country)
  uri = ENDPOINT.dup
  uri.query = URI.encode_www_form(q: name, countrycodes: country.downcase, format: "jsonv2", addressdetails: 1, limit: 1)
  response = Net::HTTP.get_response(uri, { "User-Agent" => USER_AGENT, "Accept-Language" => "en" })
  response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body).first : nil
end

candidates = CSV.read(ARGV.fetch(0), headers: true)
out = CSV.new($stdout)
out << %w[locode name subdivision region matched]

candidates.each do |row|
  locode = row["locode"].to_s.strip.upcase
  country = locode[0, 2]
  result = search(row["name"].to_s.split("/").first.strip, country)
  address = result&.fetch("address", {}) || {}
  out << [
    locode, row["name"],
    address["ISO3166-2-lvl6"] || address["ISO3166-2-lvl5"],
    address["ISO3166-2-lvl4"] || address["ISO3166-2-lvl3"],
    result && "#{result['display_name']} [#{result['category']}/#{result['type']}]"
  ]
  $stdout.flush
  sleep 1.1
end
