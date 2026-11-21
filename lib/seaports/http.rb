# frozen_string_literal: true

require "net/http"
require "uri"

require_relative "version"

module Seaports
  # The one place the build-time sources touch the network, so a test can hand
  # the code a lambda with the same shape and never open a socket:
  # +call(url, headers)+ returns [status, body], the body as raw bytes.
  #
  # Sends a generic User-Agent that names the gem and its repository and
  # nothing about whoever runs the build: NGA, the Internet Archive and
  # Wikidata all ask automated clients to say what they are.
  module Http
    USER_AGENT = "seaports-gem/#{VERSION} (https://github.com/Trackberry/seaports)"
    REDIRECTS = 5

    def self.get(url, headers = {}, redirects = REDIRECTS)
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT
      headers.each { |name, value| request[name] = value }

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 120) do |http|
        http.request(request)
      end

      if response.is_a?(Net::HTTPRedirection) && redirects.positive?
        return get(URI.join(url, response["location"]).to_s, headers, redirects - 1)
      end

      [response.code.to_i, response.body.to_s.b]
    end
  end
end
