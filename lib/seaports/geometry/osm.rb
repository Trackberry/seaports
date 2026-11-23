# frozen_string_literal: true

require "json"
require "openssl"
require "uri"

require_relative "../http"
require_relative "planar"

module Seaports
  module Geometry
    # OpenStreetMap through the Overpass API: a feature's shape by its id, and
    # the candidates near a port for a person or an agent to choose from.
    #
    # Build time only. Nothing in the gem's runtime touches the network; the
    # shapes this fetches are written into data/geometry and shipped.
    module Osm
      ENDPOINTS = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"].freeze
      RETRY_PAUSES = [20, 60, nil].freeze
      REF = %r{\A(node|way|relation)/(\d+)\z}

      class Error < StandardError; end

      module_function

      # GET a query from the first Overpass instance that answers, and parse
      # it, trying each twice more after a pause: the public instances answer a
      # busy minute with 502 or 429. +http+ has Http.get's shape and +pause+
      # Kernel#sleep's, so a test neither opens a socket nor waits.
      def query(text, http: Http.method(:get), pause: method(:sleep))
        failures = []
        RETRY_PAUSES.each do |seconds|
          ENDPOINTS.each do |endpoint|
            status, body, = http.call("#{endpoint}?data=#{URI.encode_www_form_component(text)}", {})
            return JSON.parse(body) if status == 200 && body.to_s.lstrip.start_with?("{")

            failures << "#{endpoint} answered HTTP #{status}"
          rescue JSON::ParserError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
            failures << "#{endpoint}: #{e.class}: #{e.message}"
          end
          pause.call(seconds) if seconds
        end
        raise Error, "Overpass refused the query: #{failures.uniq.join('; ')}"
      end

      # { "way/123" => geometry } for every reference, each a GeoJSON Point,
      # Polygon or MultiPolygon, or a LineString for a way that does not
      # close. Raises when OpenStreetMap no longer has one, so a deleted
      # feature is noticed by the refresh rather than shipped as a hole.
      def shapes(refs, http: Http.method(:get))
        by_type = refs.map { |ref| parse_ref(ref) }.group_by(&:first)
        statements = by_type.map { |type, pairs| "#{type}(id:#{pairs.map(&:last).join(',')});" }.join
        elements = query("[out:json][timeout:120];(#{statements});out geom;", http:)["elements"]

        found = elements.to_h { |element| ["#{element['type']}/#{element['id']}", shape(element)] }
        missing = refs - found.keys
        raise Error, "OpenStreetMap has no #{missing.join(', ')}" unless missing.empty?

        found.slice(*refs)
      end

      def parse_ref(ref)
        match = REF.match(ref.to_s)
        raise Error, "#{ref.inspect} is not an OpenStreetMap reference like way/123" unless match

        [match[1], match[2].to_i]
      end

      def shape(element)
        case element["type"]
        when "node" then { "type" => "Point", "coordinates" => position(element) }
        when "way" then way_shape(line(element["geometry"]))
        when "relation" then relation_shape(element)
        end
      end

      def position(point)
        [point["lon"].to_f.round(6), point["lat"].to_f.round(6)]
      end

      def line(points)
        (points || []).compact.map { |point| position(point) }
      end

      def way_shape(points)
        if points.size >= 4 && points.first == points.last
          { "type" => "Polygon", "coordinates" => [orient(points, outer: true)] }
        else
          { "type" => "LineString", "coordinates" => points }
        end
      end

      # A multipolygon relation's member ways, joined end to end into rings
      # and each inner ring put inside the outer ring that holds it. A
      # relation with no outer rings (a route, a site) has no area and comes
      # back as a MultiPoint of its nodes for a caller to refuse or buffer.
      def relation_shape(element)
        members = (element["members"] || []).select { |member| member["type"] == "way" }
        outers = rings(members.select { |m| m["role"] != "inner" }.map { |m| line(m["geometry"]) })
        inners = rings(members.select { |m| m["role"] == "inner" }.map { |m| line(m["geometry"]) })
        if outers.empty?
          points = (element["members"] || []).flat_map { |m| m["geometry"] ? line(m["geometry"]) : [] }
          points << position(element["center"]) if points.empty? && element["center"]
          return { "type" => "MultiPoint", "coordinates" => points.uniq }
        end

        polygons = outers.map { |ring| [orient(ring, outer: true)] }
        inners.each do |hole|
          home = polygons.find { |rings| Planar.ring_contains?(rings.first, *hole.first) } || next
          home << orient(hole, outer: false)
        end
        polygons.size == 1 ? { "type" => "Polygon", "coordinates" => polygons.first } : { "type" => "MultiPolygon", "coordinates" => polygons }
      end

      # Joins lines that share end points into closed rings. A line that
      # cannot be closed is dropped: OpenStreetMap relations are sometimes
      # broken mid-edit, and an open ring is no area at all.
      def rings(lines)
        pool = lines.reject(&:empty?).map(&:dup)
        closed = []
        until pool.empty?
          ring = pool.shift
          while ring.first != ring.last
            index = pool.index { |other| [other.first, other.last].include?(ring.last) }
            break if index.nil?

            other = pool.delete_at(index)
            ring.concat((other.first == ring.last ? other : other.reverse).drop(1))
          end
          closed << ring if ring.size >= 4 && ring.first == ring.last
        end
        closed
      end

      # GeoJSON's right-hand rule: outer rings counter-clockwise, holes
      # clockwise. Most readers do not care; some validators do.
      def orient(ring, outer:)
        signed = ring.each_cons(2).sum { |(x1, y1), (x2, y2)| (x1 * y2) - (x2 * y1) }
        counter_clockwise = signed.positive?
        counter_clockwise == outer ? ring : ring.reverse
      end
    end
  end
end
