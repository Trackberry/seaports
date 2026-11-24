# frozen_string_literal: true

require_relative "osm"
require_relative "planar"

module Seaports
  module Geometry
    # What OpenStreetMap maps inside a port's limits that is not port: homes,
    # residential areas, schools, hospitals, clinics, places of worship and
    # the labels of towns and neighbourhoods. Every limits note says
    # truthfully what lies inside; this is the scan that keeps it true.
    #
    # The build scans the final limits, from the same OpenStreetMap it
    # fetched the shapes from (Overpass, or the Geofabrik extract), and
    # stores the summary in the limits' properties as "inside". The
    # selection's +accepts+ says what reviewers read in that summary and the
    # note discloses; Inside.compare, run offline by check_geometry, fails
    # when the stored scan holds more than that, so an OpenStreetMap edit
    # that pulls housing into a port fails the weekly refresh instead of
    # shipping under a note that says there is none.
    #
    #   port_limits:
    #     accepts:
    #       houses: 8
    #       residential_m2: 1230
    #       amenities: 1
    #       places: [Les Neiges]
    #
    # Build time only, and it needs GEOS (through rgeo, as Clip does) for the
    # area of each residential polygon that lies inside the limits.
    module Inside
      HOMES = %w[house detached residential apartments dormitory terrace].freeze
      AMENITIES = %w[school hospital clinic place_of_worship].freeze
      PLACES = %w[city town village suburb neighbourhood hamlet quarter].freeze

      # A landuse=residential polygon larger than this is not a housing
      # estate but a whole town, island or district outline drawn as one
      # (some mappers tag a municipality's built-up extent that way), and the
      # part of it inside the limits says nothing about where the homes are:
      # the quays inside a town's outline would count as housing. Its homes
      # and labels are still counted on their own. The largest residential
      # areas the reviewed notes describe (Les Neiges in Le Havre, the Port
      # Town estate in Manila) are well under 1 km².
      RESIDENTIAL_CAP_M2 = 10_000_000

      # How many of the largest residential areas the summary names.
      LARGEST = 3
      # How many of the amenities it lists: the count is what is checked, the
      # list what a reviewer reads, and a city has hundreds.
      AMENITIES_LISTED = 10

      # What the build stores, how far a later scan may go past what the
      # selection accepts before it is an error: a refresh that maps one
      # more shed as a house is not news, a new estate is. Amenities and
      # places get none: one more school is one the note does not mention.
      TOLERANCE = { "houses" => [2, 0.1], "residential_m2" => [100, 0.1], "amenities" => [0, 0.0] }.freeze

      # What osmium keeps of an extract for the scan.
      FILTERS = ["nwr/building=#{HOMES.join(',')}", "wr/landuse=residential",
                 "nwr/amenity=#{AMENITIES.join(',')}", "n/place=#{PLACES.join(',')}"].freeze

      module_function

      # Elements as Overpass answers them, inside +bbox+, [west, south, east,
      # north]: homes, amenities and places with their tags and a centre,
      # residential areas with their whole geometry.
      def overpass(bbox, http: Http.method(:get))
        west, south, east, north = bbox
        box = "(#{south},#{west},#{north},#{east})"
        text = "[out:json][timeout:300];" \
               "(nwr[\"building\"~\"^(#{HOMES.join('|')})$\"]#{box};nwr[\"amenity\"~\"^(#{AMENITIES.join('|')})$\"]#{box};" \
               "node[\"place\"~\"^(#{PLACES.join('|')})$\"]#{box};);out tags center;" \
               "(way[\"landuse\"=\"residential\"]#{box};relation[\"landuse\"=\"residential\"]#{box};);out geom;"
        Osm.query(text, http:)["elements"]
      end

      # The summary of what of +elements+ lies inside +limits+, a GeoJSON
      # Polygon or MultiPolygon: a home, an amenity or a place by its centre
      # (the middle of its bounding box, which is what Overpass's "center"
      # is), a residential area by the part of it inside.
      def summary(elements, limits)
        # Made on the first element: an empty scan needs no GEOS.
        area = nil
        homes = 0
        amenities = []
        places = []
        residential = []
        too_large = []
        # Overpass answers an element in both of its blocks (a building tagged
        # landuse=residential), once with a centre and once with geometry:
        # keep the one with geometry, as the extract gives it.
        whole = ->(element) { element["geometry"] || element["members"] ? 0 : 1 }
        elements = elements.sort_by { |element| [element["type"], element["id"], whole.call(element)] }.uniq { |element| [element["type"], element["id"]] }
        elements.each do |element|
          tags = element["tags"] || {}
          ref = "#{element['type']}/#{element['id']}"
          point = centre(element)
          area ||= Area.new(limits)
          inside = point && area.contains?(*point)
          homes += 1 if inside && HOMES.include?(tags["building"])
          amenities << { "amenity" => tags["amenity"], "name" => tags["name"], "osm" => ref }.compact if inside && AMENITIES.include?(tags["amenity"])
          places << { "name" => tags["name"], "place" => tags["place"], "osm" => ref }.compact if inside && element["type"] == "node" && PLACES.include?(tags["place"])
          next unless tags["landuse"] == "residential" && element["type"] != "node"

          shape = residential_shape(element)
          next unless shape

          own = area.own_m2(shape)
          inside_m2 = area.overlap_m2(shape)
          next unless inside_m2.positive?

          entry = { "osm" => ref, "name" => tags["name"] }.compact
          if own > RESIDENTIAL_CAP_M2
            too_large << entry.merge("km2" => (own / 1_000_000.0).round(1))
          else
            residential << entry.merge("m2" => inside_m2.round)
          end
        end
        largest = residential.sort_by { |entry| [-entry["m2"], entry["osm"]] }.first(LARGEST)
        { "houses" => homes, "residential_m2" => residential.sum { |entry| entry["m2"] }, "residential" => largest,
          "residential_too_large" => too_large, "amenities" => amenities.size, "amenity" => amenities.first(AMENITIES_LISTED),
          "places" => places.sort_by { |place| [place["name"].to_s, place["osm"]] } }.reject { |_, value| value == [] }
      end

      # Errors and warnings, for Checks, from the +scan+ an outline stores
      # against what its selection +accepts+ (nil when it accepts nothing).
      def compare(scan, accepts)
        accepts ||= {}
        errors = []
        warnings = []
        TOLERANCE.each_key do |key|
          found = scan[key].to_i
          accepted = accepts[key].to_i
          allowed = accepted + tolerance(key, accepted)
          what = describe(key, scan)
          if found > allowed
            errors << "the port limits hold #{what}, more than the #{amount(key, accepted)} the selection accepts: " \
                      "if the note says so, raise accepts: #{key}; if not, the limits or the note are wrong"
          elsif accepted.positive? && found < accepted / 2.0 && accepted - found > tolerance(key, accepted)
            warnings << "the port limits hold #{what}, well below the #{amount(key, accepted)} the selection accepts: " \
                        "the note may now overstate what is inside, and accepts: #{key} can come down"
          end
        end
        accepted_places = Array(accepts["places"]).map(&:to_s)
        found = Array(scan["places"])
        found.reject { |place| accepted_places.include?(place["name"]) || accepted_places.include?(place["osm"]) }.each do |place|
          errors << "the port limits hold the place #{place['name'] || '(unnamed)'} (#{place['place']}, #{place['osm']}), which the " \
                    "selection does not accept: if the note says so, add it to accepts: places"
        end
        (accepted_places - found.flat_map { |place| [place["name"], place["osm"]] }).each do |name|
          warnings << "the selection accepts the place #{name}, which is no longer inside the port limits: the note may now overstate"
        end
        [errors, warnings]
      end

      def tolerance(key, accepted)
        least, share = TOLERANCE.fetch(key)
        [least, (accepted * share).ceil].max
      end

      def amount(key, count)
        case key
        when "houses" then "#{count} #{count == 1 ? 'house' : 'houses'}"
        when "residential_m2" then "#{count} m² of residential land"
        else "#{count} #{count == 1 ? 'school, hospital, clinic or place of worship' : 'schools, hospitals, clinics or places of worship'}"
        end
      end

      def describe(key, scan)
        text = amount(key, scan[key].to_i)
        list =
          case key
          when "residential_m2" then Array(scan["residential"]).map { |entry| "#{entry['name'] || entry['osm']}: #{entry['m2']} m²" }
          when "amenities" then Array(scan["amenity"]).map { |entry| [entry["amenity"], entry["name"], entry["osm"]].compact.join(" ") }
          else []
          end
        list.empty? ? text : "#{text} (#{list.join('; ')})"
      end

      # [lng, lat]: a node's position, Overpass's centre, or the middle of
      # the bounding box of the element's geometry.
      def centre(element)
        return [element["lon"].to_f, element["lat"].to_f] if element["lat"] && element["lon"]
        return [element["center"]["lon"].to_f, element["center"]["lat"].to_f] if element["center"]

        points = Array(element["geometry"]).compact + Array(element["members"]).flat_map { |member| Array(member["geometry"]).compact }
        return nil if points.empty?

        lngs = points.map { |point| point["lon"].to_f }
        lats = points.map { |point| point["lat"].to_f }
        [(lngs.min + lngs.max) / 2.0, (lats.min + lats.max) / 2.0]
      end

      # The area of a residential element, or nil for one that does not
      # close (mid-edit, or cut short by an extract): a broken polygon is
      # not housing to count.
      def residential_shape(element)
        shape = Osm.shape(element)
        %w[Polygon MultiPolygon].include?(shape && shape["type"]) ? shape : nil
      rescue Osm::Error
        nil
      end

      # The limits, for many questions: points inside, and how much of a
      # polygon is. In GEOS, on a plane in metres tangent at the limits'
      # centre, as Clip works, since the limits can run to thousands of
      # vertices and a city has tens of thousands of homes.
      class Area
        def initialize(limits)
          require_relative "clip"
          Clip.load_geos!
          @lng0, @lat0 = Planar.label_point(limits) || Planar.positions(limits).first
          @scale_x = Planar::M_PER_DEGREE * Math.cos(@lat0 * Math::PI / 180.0)
          @factory = RGeo::Geos.factory(native_interface: :capi)
          @box = Planar.bbox(limits)
          @limits = read(limits).make_valid
          @limits.prepare!
        end

        def contains?(lng, lat)
          return false unless lng.between?(@box[0], @box[2]) && lat.between?(@box[1], @box[3])

          @limits.contains?(@factory.point(*local([lng, lat])))
        end

        # The area of a polygon once made valid, as GEOS measures it: a
        # self-crossing ring's own shoelace area can be near nothing.
        def own_m2(geometry) = area(read(geometry).make_valid)

        def overlap_m2(geometry)
          west, south, east, north = Planar.bbox(geometry)
          return 0.0 if east < @box[0] || west > @box[2] || north < @box[1] || south > @box[3]

          shape = read(geometry).make_valid
          return 0.0 unless @limits.intersects?(shape)

          area(@limits.intersection(shape))
        end

        private

        # A collection (a polygon and a line where the two touch along an
        # edge) has no area of its own: its polygons' areas.
        def area(geometry)
          case geometry.geometry_type.type_name
          when "Polygon", "MultiPolygon" then geometry.area
          when "GeometryCollection" then Array.new(geometry.num_geometries) { |i| area(geometry.geometry_n(i)) }.sum
          else 0.0
          end
        end

        def local((lng, lat)) = [(lng - @lng0) * @scale_x, (lat - @lat0) * Planar::M_PER_DEGREE]

        def read(geometry)
          text = Planar.polygons(geometry).map do |rings|
            "(#{rings.map { |positions| "(#{positions.map { |position| local(position).join(' ') }.join(', ')})" }.join(', ')})"
          end
          @factory.parse_wkt("MULTIPOLYGON (#{text.join(', ')})")
        end
      end
    end
  end
end
