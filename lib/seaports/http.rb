# frozen_string_literal: true

require "net/http"
require "uri"

require_relative "version"

module Seaports
  # The one place the build-time sources touch the network, so a test can hand
  # the code a lambda with the same shape and never open a socket:
  # +call(url, headers)+ returns [status, body, headers], the body as raw
  # bytes and the headers lower-cased. A caller must accept a stub that
  # returns only [status, body].
  #
  # Sends a generic User-Agent that names the gem and its repository and
  # nothing about whoever runs the build: NGA, the Internet Archive and
  # Wikidata all ask automated clients to say what they are.
  module Http
    USER_AGENT = "seaports-gem/#{VERSION} (https://github.com/Trackberry/seaports)"
    REDIRECTS = 5

    # The largest body read. The biggest thing fetched is Natural Earth's
    # 40 MB map; a body past this is the wrong document, and reading it all
    # would only fill the disk.
    MAX_BYTES = 120 * 1024 * 1024

    class TooLarge < StandardError; end

    def self.get(url, headers = {}, redirects = REDIRECTS, max_bytes = MAX_BYTES)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      headers.each { |name, value| request[name] = value }

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 120) do |http|
        http.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection) && redirects.positive?
            return get(URI.join(url, response["location"]).to_s, headers, redirects - 1, max_bytes)
          end

          body = String.new(encoding: Encoding::BINARY)
          response.read_body do |chunk|
            body << chunk
            raise TooLarge, "#{url} is larger than #{max_bytes} bytes" if body.bytesize > max_bytes
          end
          return [response.code.to_i, body, response.to_hash.transform_values(&:first)]
        end
      end
    end
  end
end
