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
# overrides file: a name search can match the wrong Valencia. A lookup that
# failed says "error:", one that found nothing says "no match".
#
# The matched place names are OpenStreetMap data, © OpenStreetMap
# contributors, available under the ODbL; the overrides file credits them.

require "csv"
require "json"
require "net/http"
require "uri"

ENDPOINT = URI("https://nominatim.openstreetmap.org/search")
USER_AGENT = "trackberry-seaports-build (+https://github.com/Trackberry/seaports)"
PAUSE = 1.1 # Nominatim's policy: at most one request a second
ATTEMPTS = 3

# The first match, nil when Nominatim found nothing, or raises when it could
# not be asked. A refusal (429 or 403, the usage policy pushing back) waits
# and tries again; it must never read as "no match", or a port would look
# searched and unplaceable when it was neither.
def search(name, country, attempt: 1)
  uri = ENDPOINT.dup
  uri.query = URI.encode_www_form(q: name, countrycodes: country.downcase, format: "jsonv2", addressdetails: 1, limit: 1)
  request = Net::HTTP::Get.new(uri, "User-Agent" => USER_AGENT, "Accept-Language" => "en")
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
  raise "Nominatim answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body).first
rescue StandardError => e
  raise if attempt >= ATTEMPTS

  warn "#{name}: #{e.message}, retrying"
  sleep 30 * attempt
  search(name, country, attempt: attempt + 1)
end

candidates = CSV.read(ARGV.fetch(0), headers: true)
out = CSV.new($stdout)
out << %w[locode name subdivision region matched]

candidates.each do |row|
  locode = row["locode"].to_s.strip.upcase
  country = locode[0, 2]
  begin
    result = search(row["name"].to_s.split("/").first.strip, country)
    address = result&.fetch("address", {}) || {}
    out << [
      locode, row["name"],
      address["ISO3166-2-lvl6"] || address["ISO3166-2-lvl5"],
      address["ISO3166-2-lvl4"] || address["ISO3166-2-lvl3"],
      result ? "#{result['display_name']} [#{result['category']}/#{result['type']}]" : "no match"
    ]
  rescue StandardError => e
    out << [locode, row["name"], nil, nil, "error: #{e.message}"]
  end
  $stdout.flush
  sleep PAUSE
end
