# frozen_string_literal: true

require_relative "osm"

module Seaports
  module Geometry
    # The water OpenStreetMap maps around a port, for Clip to cut port limits
    # to: the coastline, which bounds the sea, and the areas mapped as water
    # (rivers, docks, basins, lakes, canals drawn as areas).
    #
    # Build time only, like Osm. Asks Overpass by default; Extract#water_for
    # answers the same question from a Geofabrik extract.
    #
    # Left out on purpose: landuse=harbour, which in OpenStreetMap is often
    # the whole port, quays and sheds included; man_made=pier, which is land
    # a ship lies against (a terminal mapped over a pier is kept whole by
    # Clip anyway); and waterways drawn only as lines, which have no width.
    # A port whose river is mapped only as a line is caught by the check that
    # every terminal touches water.
    module Water
      AREA_WATERWAYS = %w[riverbank dock canal].freeze
      AREA_TYPES = %w[Polygon MultiPolygon].freeze

      module_function

      # +bbox+ is [west, south, east, north]. Answers
      # { "coastline" => [[[lng, lat], ...], ...], "areas" => [geometry, ...],
      #   "skipped" => ["relation/1: why", ...] }.
      def overpass(bbox, http: Http.method(:get))
        west, south, east, north = bbox
        box = "#{south},#{west},#{north},#{east}"
        text = "[out:json][timeout:180][bbox:#{box}];(" \
               'way["natural"="coastline"];' \
               'way["natural"="water"];relation["natural"="water"];' \
               "way[\"waterway\"~\"^(#{AREA_WATERWAYS.join('|')})$\"];relation[\"waterway\"=\"riverbank\"];" \
               ");out geom;"
        classify(Osm.query(text, http:)["elements"])
      end

      # The query's answer, or Extract's, sorted into coastline lines and
      # water areas. A water relation that does not close (mid-edit, or cut
      # by an extract) is skipped and named rather than failing the build:
      # what it leaves dry, the terminal check sees.
      def classify(elements)
        result = { "coastline" => [], "areas" => [], "skipped" => [] }
        elements.sort_by { |element| [element["type"], element["id"]] }.each do |element|
          tags = element["tags"] || {}
          ref = "#{element['type']}/#{element['id']}"
          if element["type"] == "way" && tags["natural"] == "coastline"
            line = Osm.line(element["geometry"])
            result["coastline"] << line if line.size >= 2
          elsif area?(tags)
            begin
              shape = Osm.shape(element)
              if AREA_TYPES.include?(shape && shape["type"])
                result["areas"] << shape
              elsif element["type"] == "relation"
                result["skipped"] << "#{ref}: no closed outer ring"
              end
            rescue Osm::Error => e
              result["skipped"] << "#{ref}: #{e.message}"
            end
          end
        end
        result
      end

      def area?(tags)
        return false if tags["area"] == "no"

        tags["natural"] == "water" || (AREA_WATERWAYS.include?(tags["waterway"]) && (tags["waterway"] != "canal" || tags["area"] == "yes"))
      end
    end
  end
end
