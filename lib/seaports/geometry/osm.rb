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
      REF = %r{\A(node|way|relation)/([1-9]\d*)\z}
      # The tags a terminal's or an anchorage's name is checked against (the
      # name rule, in Checks), stored in its outline as "osm_tags".
      NAME_TAGS = %w[name name:en seamark:name].freeze

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
            if status == 200 && body.to_s.lstrip.start_with?("{")
              data = JSON.parse(body)
              # Overpass answers a timeout or an exhausted memory quota with
              # 200 and a "remark", over whatever it had found so far: a
              # partial answer that must not pass for a whole one.
              return data unless data["remark"].to_s.match?(/error|timed out|out of memory/i)

              failures << "#{endpoint} stopped early: #{data['remark'].to_s.strip[0, 200]}"
            else
              failures << "#{endpoint} answered HTTP #{status}"
            end
          # Anything the network or a body can throw: DNS (SocketError), a
          # malformed response, a body over Http's cap. Each is a reason to
          # try the next instance, not to stop.
          rescue StandardError => e
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
      #
      # +tags+, a Hash, is filled with each reference's NAME_TAGS from the
      # same answer, so the names cost no second query.
      def shapes(refs, http: Http.method(:get), tags: nil)
        by_type = refs.map { |ref| parse_ref(ref) }.group_by(&:first)
        statements = by_type.map { |type, pairs| "#{type}(id:#{pairs.map(&:last).join(',')});" }.join
        elements = query("[out:json][timeout:120];(#{statements});out geom;", http:)["elements"]

        found = elements.to_h { |element| ["#{element['type']}/#{element['id']}", shape(element)] }
        elements.each { |element| tags["#{element['type']}/#{element['id']}"] = name_tags(element["tags"]) } if tags
        missing = refs - found.keys
        raise Error, "OpenStreetMap has no #{missing.join(', ')}" unless missing.empty?

        found.slice(*refs)
      end

      # The NAME_TAGS among an element's +tags+, in NAME_TAGS's order.
      def name_tags(tags)
        tags ||= {}
        NAME_TAGS.filter_map { |key| [key, tags[key]] unless tags[key].to_s.strip.empty? }.to_h
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
      #
      # A relation whose rings do not all close, or with a hole outside every
      # outer ring, raises: OpenStreetMap relations are sometimes broken
      # mid-edit, and shipping the closed half of a terminal would look like a
      # small move in a refresh rather than the breakage it is.
      def relation_shape(element)
        ref = "relation/#{element['id']}"
        members = (element["members"] || []).select { |member| member["type"] == "way" }
        outers, open_outers = rings(members.select { |m| m["role"] != "inner" }.map { |m| line(m["geometry"]) })
        inners, open_inners = rings(members.select { |m| m["role"] == "inner" }.map { |m| line(m["geometry"]) })
        broken = open_outers + open_inners
        raise Error, "#{ref} has #{broken} ring part(s) that do not close: fix it in OpenStreetMap or wait for the edit to finish" if broken.positive?

        if outers.empty?
          points = (element["members"] || []).flat_map { |m| m["geometry"] ? line(m["geometry"]) : [] }
          points << position(element["center"]) if points.empty? && element["center"]
          return { "type" => "MultiPoint", "coordinates" => points.uniq }
        end

        polygons = outers.map { |ring| [orient(ring, outer: true)] }
        inners.each do |hole|
          # Any vertex strictly inside will do: OpenStreetMap lets a hole touch
          # its outer ring, so the first vertex may sit on the boundary.
          home = polygons.find { |rings| hole.any? { |vertex| Planar.ring_contains?(rings.first, *vertex) } }
          raise Error, "#{ref} has a hole outside every outer ring" unless home

          home << orient(hole, outer: false)
        end
        polygons.size == 1 ? { "type" => "Polygon", "coordinates" => polygons.first } : { "type" => "MultiPolygon", "coordinates" => polygons }
      end

      # Joins lines that share end points into closed rings. Answers the
      # closed rings and how many chains could not be closed.
      def rings(lines)
        pool = lines.reject(&:empty?).map(&:dup)
        closed = []
        open = 0
        until pool.empty?
          ring = pool.shift
          while ring.first != ring.last
            index = pool.index { |other| [other.first, other.last].include?(ring.last) }
            break if index.nil?

            other = pool.delete_at(index)
            ring.concat((other.first == ring.last ? other : other.reverse).drop(1))
          end
          if ring.size >= 4 && ring.first == ring.last
            closed << ring
          else
            open += 1
          end
        end
        [closed, open]
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
