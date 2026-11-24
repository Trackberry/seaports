# frozen_string_literal: true

require "test_helper"
require "seaports/geometry/builder"
require "seaports/geometry/checks"
require "seaports/geometry/inside"
require "seaports/geometry/selection"

# The checks that replace a reviewer reading every outline by hand: names
# are OpenStreetMap's own, notes quote OpenStreetMap truthfully, and what
# OpenStreetMap maps inside the limits is no more than the selection accepts.
module QualityFixtures
  LIMITS = [[4.4, 51.85], [4.6, 51.85], [4.6, 52.0], [4.4, 52.0], [4.4, 51.85]].freeze
  TERMINAL = [[4.49, 51.91], [4.51, 51.91], [4.51, 51.92], [4.49, 51.92], [4.49, 51.91]].freeze
  ANCHORAGE = [[4.42, 51.86], [4.44, 51.86], [4.44, 51.87], [4.42, 51.87], [4.42, 51.86]].freeze

  def polygon(ring) = { "type" => "Polygon", "coordinates" => [ring] }

  def feature(kind, ring, **props)
    stored = kind == "port_limits" ? { "inside" => { "houses" => 0, "residential_m2" => 0, "amenities" => 0 } } : {}
    { "type" => "Feature", "geometry" => polygon(ring),
      "properties" => { "kind" => kind, "osm" => ["way/1"], "source" => "test", "licence" => "ODbL-1.0", "reviewed_at" => "2026-11-23",
                        "note" => "n", "cargo" => ["bulk"], "category" => "general" }.merge(stored).merge(props.transform_keys(&:to_s)) }
  end

  def collection(*features)
    { "type" => "FeatureCollection", "locode" => "NLRTM", "quays" => [], "attribution" => "© OpenStreetMap", "features" => features }
  end

  def terminal(name, tags, note: "n") = feature("terminal", TERMINAL, name:, osm_tags: tags, note:)

  def run_checks(*features, selection: nil) = Seaports::Geometry::Checks.run(collection(feature("port_limits", LIMITS), *features), selection:)

  def geos?
    require "rgeo"
    RGeo::Geos.capi_supported?
  rescue LoadError
    false
  end

  def need_geos!
    return if geos?
    raise "GEOS is not installed: apt-get install libgeos-dev" if ENV["CI"]

    skip "GEOS is not installed: brew install geos"
  end
end

class GeometryNameRuleTest < Minitest::Test
  include QualityFixtures
  Checks = Seaports::Geometry::Checks

  def name_errors(result) = result.errors.grep(/so the name must be|stores no OpenStreetMap names/)

  def test_a_name_equal_to_openstreetmaps_passes
    assert_empty name_errors(run_checks(terminal("Euromax Terminal", { "name" => "Euromax Terminal" })))
  end

  def test_a_name_of_its_own_is_an_error
    errors = name_errors(run_checks(terminal("Euromax", { "name" => "Euromax Terminal" })))

    assert_equal ['terminal Euromax: OpenStreetMap\'s way/1 has name=Euromax Terminal, so the name must be "Euromax Terminal", not "Euromax"'], errors
  end

  def test_name_en_is_allowed_only_for_a_name_in_another_script
    chinese = { "name" => "大铲湾集装箱码头", "name:en" => "Dachan Bay Container Terminal" }
    french = { "name" => "Terminal de France", "name:en" => "France Terminal" }

    assert_empty name_errors(run_checks(terminal("Dachan Bay Container Terminal", chinese)))
    assert_empty name_errors(run_checks(terminal("大铲湾集装箱码头", chinese)))
    refute_empty name_errors(run_checks(terminal("France Terminal", french)))
  end

  # Vietnamese is written in Latin letters, diacritics and all.
  def test_latin_letters_with_diacritics_are_not_another_script
    refute Checks.non_latin?("Cảng Tổng hợp Thị Vải")
    assert Checks.non_latin?("River Trade Terminal (內河貨運碼頭)")
  end

  def test_seamark_name_is_allowed_only_for_an_unnamed_seamark
    assert_empty name_errors(run_checks(feature("anchorage", ANCHORAGE, name: "No 3", osm_tags: { "seamark:name" => "No 3" })))
    named = { "name" => "Anchorage No 3", "seamark:name" => "No 3" }

    refute_empty name_errors(run_checks(feature("anchorage", ANCHORAGE, name: "No 3", osm_tags: named)))
  end

  def test_a_feature_openstreetmap_leaves_unnamed_takes_a_neutral_name
    assert_empty name_errors(run_checks(terminal("Berths", {})))
    assert_empty name_errors(run_checks(feature("anchorage", ANCHORAGE, name: "Anchorage", osm_tags: {})))
    assert_equal ["Anchorage", "Container terminal", "Berths"], Checks.allowed_names({})

    error = name_errors(run_checks(terminal("Lekki Deep Sea Port", {}))).first
    assert_match 'has no name, so the name must be "Anchorage" or "Container terminal" or "Berths"', error
  end

  def test_an_outline_built_without_the_tags_is_an_error
    errors = name_errors(run_checks(feature("terminal", TERMINAL, name: "Euromax Terminal")))

    assert_equal 1, errors.size
    assert_match "rebuild it", errors.first
  end

  # Pilot boarding places keep the names their notes give them.
  def test_a_pilot_boarding_place_is_not_held_to_the_rule
    pilot = { "type" => "Feature", "geometry" => { "type" => "Point", "coordinates" => [4.5, 51.9] },
              "properties" => { "kind" => "pilot_boarding", "name" => "Maas Center", "osm" => ["node/4"], "source" => "t",
                                "licence" => "ODbL-1.0", "reviewed_at" => "2026-11-23", "note" => "n" } }

    assert_empty name_errors(run_checks(pilot))
  end

  # The build stores the tags of a feature's first-listed element, which is
  # what the rule reads for a terminal mapped in parts.
  def test_the_build_stores_the_first_listed_elements_tags
    shapes = ->(refs) { refs.to_h { |ref| [ref, polygon(TERMINAL)] } }
    tags = ->(refs) { { "way/7" => { "name" => "Seventh" }, "way/8" => { "name" => "Eighth" } }.slice(*refs) }
    selection = { "locode" => "NLRTM", "reviewed_at" => "2026-11-23",
                  "features" => [{ "osm" => %w[way/8 way/7], "kind" => "terminal", "name" => "Eighth" },
                                 { "osm" => "way/7", "kind" => "pilot_boarding", "name" => "P", "buffer_m" => 10 }] }
    features = Seaports::Geometry::Builder.new(selection, shapes:, tags:).build["features"]

    assert_equal({ "name" => "Eighth" }, features.first["properties"]["osm_tags"])
    assert_nil features.last["properties"]["osm_tags"]
  end

  def test_name_tags_keeps_only_the_names
    tags = { "name" => "Euromax", "operator" => "ECT", "name:en" => " ", "seamark:name" => "E", "short_name" => "EMX" }

    assert_equal({ "name" => "Euromax", "seamark:name" => "E" }, Seaports::Geometry::Osm.name_tags(tags))
  end

  def test_overpass_fills_the_tags_from_the_shapes_answer
    body = JSON.generate({ "elements" => [{ "type" => "node", "id" => 4, "lat" => 51.9, "lon" => 4.5,
                                            "tags" => { "name" => "Maas Center", "seamark:type" => "pilot_boarding" } }] })
    tags = {}
    Seaports::Geometry::Osm.shapes(["node/4"], http: ->(*) { [200, body] }, tags:)

    assert_equal({ "node/4" => { "name" => "Maas Center" } }, tags)
  end
end

class GeometryNoteClaimTest < Minitest::Test
  include QualityFixtures

  def claim_errors(result) = result.errors.grep(/the note says/)

  def test_a_true_claim_passes
    note = "Seamark area named No 3 in OpenStreetMap, east of the first."
    result = run_checks(feature("anchorage", ANCHORAGE, name: "No 3", osm_tags: { "seamark:name" => "No 3" }, note:))

    assert_empty claim_errors(result)
  end

  def test_a_claim_openstreetmap_no_longer_bears_out_is_an_error
    note = "Seamark area named No 3 in OpenStreetMap."
    result = run_checks(feature("anchorage", ANCHORAGE, name: "No 4", osm_tags: { "seamark:name" => "No 4" }, note:))

    assert_equal ['anchorage No 4: the note says it is named "No 3" in OpenStreetMap, which has seamark:name="No 4": correct the note'],
      claim_errors(result)
  end

  def test_named_so_claims_the_features_own_name
    good = terminal("LOTUS PORT", { "name" => "LOTUS PORT" }, note: "Lotus port, named so in OpenStreetMap.")
    stale = terminal("Lotus Port", { "name" => "Lotus Port" }, note: "Lotus port, named so in OpenStreetMap.")

    assert_empty claim_errors(run_checks(good))
    # The name rule fails it too; the claim is the feature's own name.
    assert_empty claim_errors(run_checks(stale))
    stale["properties"]["osm_tags"] = { "name" => "LOTUS" }
    refute_empty claim_errors(run_checks(stale))
  end

  def test_a_quoted_claim_and_a_gloss_in_brackets
    tags = { "name" => "内河货运码头", "name:en" => "River Trade Terminal" }
    note = 'Tagged cargo=general and named River Trade Terminal (内河货运码头) in OpenStreetMap, and "River Trade Terminal" in English.'

    assert_empty claim_errors(run_checks(terminal("River Trade Terminal", tags, note:)))
    quoted = terminal("No5", { "seamark:name" => "No5" }, note: 'Seamark area named "No5" in OpenStreetMap.')
    assert_empty claim_errors(run_checks(quoted))
    misquoted = terminal("No5", { "seamark:name" => "No5" }, note: 'Seamark area named "No.5" in OpenStreetMap.')
    assert_equal ['terminal No5: the note says it is named "No.5" in OpenStreetMap, which has seamark:name="No5": correct the note'],
      claim_errors(run_checks(misquoted))
  end

  def test_names_it_must_be_a_name_and_spells_it_part_of_one
    tags = { "name" => "West Hinder Achorage" }

    assert_empty claim_errors(run_checks(terminal("West Hinder Achorage", tags, note: 'OpenStreetMap spells it "Achorage".')))
    error = claim_errors(run_checks(terminal("West Hinder Achorage", tags, note: 'OpenStreetMap names it "West Hinder".'))).first
    assert_match 'the note says OpenStreetMap names it "West Hinder", but it has name="West Hinder Achorage"', error
  end

  # An abbreviation's full stop ends no sentence.
  def test_a_claim_reads_past_an_abbreviation
    assert_empty claim_errors(run_checks(terminal("No. 5", { "seamark:name" => "No. 5" }, note: "Seamark area named No. 5 in OpenStreetMap.")))
    assert_empty claim_errors(run_checks(terminal("St. Helier Quay", { "name" => "St. Helier Quay" }, note: "Named St. Helier Quay in OpenStreetMap.")))
    error = claim_errors(run_checks(terminal("No. 5", { "seamark:name" => "No. 5" }, note: "Seamark area named No. 6 in OpenStreetMap."))).first
    assert_match 'named "No. 6" in OpenStreetMap', error
  end

  def test_a_quoted_name_before_and_is_the_claim
    note = 'Named "No5" and tagged anchorage in OpenStreetMap.'

    assert_empty claim_errors(run_checks(terminal("No5", { "seamark:name" => "No5" }, note:)))
    refute_empty claim_errors(run_checks(terminal("No6", { "seamark:name" => "No6" }, note:)))
  end

  def test_not_named_is_no_claim
    note = "The berth is not named Pier 7 in OpenStreetMap, which gives it no name."

    assert_empty claim_errors(run_checks(terminal("Berths", {}, note:)))
  end

  def test_named_for_something_is_no_claim
    note = "Tagged industrial=port and named for the whole port in OpenStreetMap."

    assert_empty claim_errors(run_checks(terminal("Puerto de Las Palmas", { "name" => "Puerto de Las Palmas" }, note:)))
  end

  def test_a_claim_stays_within_its_sentence
    tags = { "name" => "Berth 5" }
    across = "It is named Berth 5 by the port; in OpenStreetMap it is a quay. Named Pier 7. It is also mapped in OpenStreetMap as a pier."

    assert_empty claim_errors(run_checks(terminal("Berth 5", tags, note: across)))
    capital = terminal("Berth 5", tags, note: "Named Pier 7 in OSM, by the river.")
    assert_equal 1, claim_errors(run_checks(capital)).size
    single = terminal("Berth 5", tags, note: "OpenStreetMap calls it ‘Pier’.")
    assert_equal 1, claim_errors(run_checks(single)).size
    tagged = terminal("Berth 5", tags, note: "Named Berth 5 and tagged cargo=container in OpenStreetMap.")
    assert_empty claim_errors(run_checks(tagged))
  end

  def test_a_quote_left_behind_by_a_rename_is_a_warning
    limits = feature("port_limits", LIMITS, note: 'The quays of "MSC Terminal Valencia" are kept whole.')
    msc = terminal("MSC Terminal", { "name" => "MSC Terminal" })
    result = Seaports::Geometry::Checks.run(collection(limits, msc))

    assert_includes result.warnings,
      'the port limits: the note quotes "MSC Terminal Valencia", which is no feature\'s name now: is it "MSC Terminal", renamed?'
    assert result.errors.grep(/quotes/).empty?, "a warning, not an error"
  end

  # Singapore's note quotes a "Port" label the scan finds on a terminal.
  def test_a_quoted_place_the_scan_found_is_no_stale_name
    inside = { "houses" => 0, "places" => [{ "name" => "Port", "place" => "neighbourhood", "osm" => "node/1" }] }
    limits = feature("port_limits", LIMITS, note: 'A "Port" label on the terminal.', inside:)
    result = Seaports::Geometry::Checks.run(collection(limits, terminal("Tuas Mega Port", { "name" => "Tuas Mega Port" })))

    assert_empty result.warnings.grep(/quotes/)
  end

  def test_a_quote_in_a_features_own_note_must_be_a_name_it_has
    ok = terminal("Zeebrugge lng-terminal", { "name" => "Zeebrugge lng-terminal" }, note: 'Known as "Zeebrugge lng-terminal".')
    odd = terminal("Zeebrugge lng-terminal", { "name" => "Zeebrugge lng-terminal" }, note: 'Known as "Fluxys LNG".')

    assert_empty run_checks(ok).warnings.grep(/quotes/)
    assert_equal ['terminal Zeebrugge lng-terminal: the note quotes "Fluxys LNG", which is neither its name nor a name OpenStreetMap gives it'],
      run_checks(odd).warnings.grep(/quotes/)
  end
end

class GeometryInsideScanTest < Minitest::Test
  include QualityFixtures
  Inside = Seaports::Geometry::Inside

  def setup = need_geos!

  # Small squares around a point, [lng, lat], about +half+ degrees across.
  def square_way(id, lng, lat, half, tags)
    ring = [[lng - half, lat - half], [lng + half, lat - half], [lng + half, lat + half], [lng - half, lat + half], [lng - half, lat - half]]
    { "type" => "way", "id" => id, "tags" => tags, "geometry" => ring.map { |x, y| { "lon" => x, "lat" => y } } }
  end

  def node(id, lng, lat, tags) = { "type" => "node", "id" => id, "lat" => lat, "lon" => lng, "tags" => tags }

  def limits = polygon(LIMITS)

  def test_counts_homes_amenities_and_places_by_their_centre
    elements = [
      square_way(1, 4.5, 51.9, 0.0001, { "building" => "house" }),
      square_way(2, 4.5, 51.9, 0.0001, { "building" => "warehouse" }),
      square_way(3, 4.7, 51.9, 0.0001, { "building" => "house" }),
      { "type" => "way", "id" => 4, "tags" => { "building" => "apartments" }, "center" => { "lat" => 51.95, "lon" => 4.45 } },
      node(5, 4.5, 51.9, { "amenity" => "school", "name" => "Les Neiges" }),
      node(6, 4.5, 51.9, { "place" => "hamlet", "name" => "Les Neiges" }),
      node(7, 4.7, 51.9, { "place" => "town", "name" => "Outside" }),
      square_way(8, 4.5, 51.9, 0.01, { "place" => "suburb", "name" => "An outline, not a label" })
    ]
    scan = Inside.summary(elements, limits)

    assert_equal 2, scan["houses"]
    assert_equal 1, scan["amenities"]
    assert_equal [{ "amenity" => "school", "name" => "Les Neiges", "osm" => "node/5" }], scan["amenity"]
    assert_equal [{ "name" => "Les Neiges", "place" => "hamlet", "osm" => "node/6" }], scan["places"]
  end

  def test_residential_land_counts_only_the_part_inside
    # Half in, half out across the east edge at 4.6.
    straddling = square_way(1, 4.6, 51.9, 0.001, { "landuse" => "residential", "name" => "Edge" })
    whole = square_way(2, 4.5, 51.9, 0.0005, { "landuse" => "residential" })
    scan = Inside.summary([straddling, whole], limits)
    full = Seaports::Geometry::Planar.area_m2(Seaports::Geometry::Osm.shape(straddling))

    assert_in_delta full / 2, scan["residential"].find { |entry| entry["osm"] == "way/1" }["m2"], full * 0.01
    assert_equal scan["residential"].sum { |entry| entry["m2"] }, scan["residential_m2"]
    assert_equal "Edge", scan["residential"].max_by { |entry| entry["m2"] }["name"]
  end

  # A town's whole outline tagged landuse=residential says nothing about
  # where its homes are.
  def test_a_town_sized_residential_polygon_is_named_but_not_counted
    town = square_way(1, 4.5, 51.9, 0.03, { "landuse" => "residential", "name" => "Whole town" })
    scan = Inside.summary([town], limits)

    assert_equal 0, scan["residential_m2"]
    assert_equal "Whole town", scan["residential_too_large"].first["name"]
  end

  # Overpass gives a building tagged landuse=residential twice: with a centre
  # in its first block and with geometry in its second.
  def test_an_element_given_twice_keeps_its_geometry
    whole = square_way(1, 4.5, 51.9, 0.001, { "building" => "residential", "landuse" => "residential" })
    centre = whole.except("geometry").merge("center" => { "lat" => 51.9, "lon" => 4.5 })
    expected = Inside.summary([whole], limits)

    assert_operator expected["residential_m2"], :>, 0
    assert_equal expected, Inside.summary([centre, whole], limits)
    assert_equal 1, Inside.summary([centre, whole], limits)["houses"]
  end

  # A town-sized outline drawn as a bowtie has almost no shoelace area.
  def test_the_size_cap_measures_the_valid_shape
    corner = [4.47, 51.87]
    ring = [corner, [4.53, 51.93], [4.53, 51.87], [4.47, 51.93], corner].map { |x, y| { "lon" => x, "lat" => y } }
    bowtie = { "type" => "way", "id" => 1, "tags" => { "landuse" => "residential" }, "geometry" => ring }

    assert_equal 0, Inside.summary([bowtie], limits)["residential_m2"]
  end

  # A residential relation that does not close, and what the extract could
  # only give in part, are counted as skipped rather than lost.
  def test_what_cannot_be_read_is_counted_as_skipped
    broken = { "type" => "relation", "id" => 9, "tags" => { "landuse" => "residential" },
               "members" => [{ "type" => "way", "role" => "outer", "geometry" => [{ "lon" => 4.5, "lat" => 51.9 }, { "lon" => 4.51, "lat" => 51.9 }] }] }

    assert_equal 3, Inside.summary([broken], limits, skipped: 2)["skipped"]
    refute Inside.summary([], limits).key?("skipped")
  end

  def test_an_empty_scan_needs_nothing_but_counts
    assert_equal({ "houses" => 0, "residential_m2" => 0, "amenities" => 0 }, Inside.summary([], limits))
  end

  def test_the_build_stores_the_scan_on_the_limits
    shapes = ->(refs) { refs.to_h { |ref| [ref, polygon(TERMINAL)] } }
    asked = []
    inside = ->(bbox) { asked << bbox; [node(1, 4.5, 51.915, { "building" => "house" })] }
    selection = { "locode" => "NLRTM", "reviewed_at" => "2026-11-23", "port_limits" => { "derive" => "hull", "buffer_m" => 500 },
                  "features" => [{ "osm" => "way/1", "kind" => "terminal", "name" => "T" }] }
    limits = Seaports::Geometry::Builder.new(selection, shapes:, inside:).build["features"].first

    assert_equal 1, limits["properties"]["inside"]["houses"]
    assert_equal [Seaports::Geometry::Planar.bbox(limits["geometry"]).map { |value| value.round(6) }], asked
  end
end

class GeometryAcceptsTest < Minitest::Test
  include QualityFixtures
  Inside = Seaports::Geometry::Inside
  Builder = Seaports::Geometry::Builder

  def scan(**counts) = { "houses" => 0, "residential_m2" => 0, "amenities" => 0 }.merge(counts.transform_keys(&:to_s))

  def test_nothing_found_and_nothing_accepted_passes
    assert_equal [[], []], Inside.compare(scan, nil)
  end

  def test_more_than_accepted_is_an_error
    errors, = Inside.compare(scan(houses: 14), { "houses" => 8 })

    assert_equal ["the port limits hold 14 houses, more than the 8 houses the selection accepts: if the note says so, raise " \
                  "accepts: houses; if not, the limits or the note are wrong"], errors
  end

  def test_a_little_more_is_within_the_tolerance
    assert_empty Inside.compare(scan(houses: 10, residential_m2: 1300), { "houses" => 8, "residential_m2" => 1230 }).first
    refute_empty Inside.compare(scan(residential_m2: 1400), { "residential_m2" => 1230 }).first
    refute_empty Inside.compare(scan(amenities: 2), { "amenities" => 1 }).first, "one more school is news"
  end

  def test_missing_accepts_accepts_nothing
    errors, = Inside.compare(scan(residential_m2: 150, "residential" => [{ "osm" => "way/9", "m2" => 150 }]), nil)

    assert_match "150 m² of residential land (way/9: 150 m²), more than the 0 m²", errors.first
  end

  def test_well_below_what_is_accepted_is_a_warning
    errors, warnings = Inside.compare(scan(houses: 1), { "houses" => 40 })

    assert_empty errors
    assert_match "well below the 40 houses the selection accepts: the note may now overstate", warnings.first
  end

  # Cartagena's town outline is 9.1 km² and counted; grown past 10 km² it
  # would drop out of residential_m2 unseen, but for this warning.
  def test_a_residential_area_newly_over_the_cap_is_a_warning
    cartagena = { "osm" => "relation/19803548", "km2" => 10.5 }
    _, warnings = Inside.compare(scan("residential_too_large" => [cartagena]), { "residential_m2" => 23_750 })

    assert(warnings.any? { |line| line.include?("relation/19803548, 10.5 km²") && line.include?("not counted") })
    assert(warnings.any? { |line| line.include?("well below the 23750 m²") })
  end

  def test_an_accepted_large_residential_area_warns_only_when_it_grows
    large = { "osm" => "relation/7", "km2" => 12.0 }

    assert_empty Inside.compare(scan("residential_too_large" => [large]), { "too_large" => { "relation/7" => 11.5 } }).last
    _, warnings = Inside.compare(scan("residential_too_large" => [large.merge("km2" => 14.0)]), { "too_large" => { "relation/7" => 11.5 } })
    assert_match "has grown from the 11.5 km²", warnings.first
  end

  def test_skipped_elements_are_a_warning
    _, warnings = Inside.compare(scan("skipped" => 2), nil)

    assert_match "skipped 2 element(s)", warnings.first
  end

  def test_places_are_accepted_by_name_or_reference
    places = [{ "name" => "Les Neiges", "place" => "neighbourhood", "osm" => "node/1" }, { "place" => "hamlet", "osm" => "node/2" }]

    assert_equal [[], []], Inside.compare(scan("places" => places), { "places" => ["Les Neiges", "node/2"] })
    errors, = Inside.compare(scan("places" => places), { "places" => ["node/2"] })
    assert_equal ["the port limits hold the place Les Neiges (neighbourhood, node/1), which the selection does not accept: if the note says so, " \
                  "add it to accepts: places"], errors
    _, warnings = Inside.compare(scan, { "places" => ["Les Neiges"] })
    assert_match "accepts the place Les Neiges, which is no longer inside", warnings.first
  end

  def test_checks_hold_the_stored_scan_to_the_selection
    limits = feature("port_limits", LIMITS, inside: scan(houses: 30))
    selection = { "port_limits" => { "accepts" => { "houses" => 8 } } }

    assert(Seaports::Geometry::Checks.run(collection(limits), selection:).errors.any? { |line| line.include?("30 houses") })
    assert(Seaports::Geometry::Checks.run(collection(limits)).errors.none? { |line| line.include?("30 houses") }, "no selection, no comparison")
  end

  def test_limits_without_a_scan_are_an_error
    limits = feature("port_limits", LIMITS)
    limits["properties"].delete("inside")

    assert_includes Seaports::Geometry::Checks.run(collection(limits)).errors,
      "the port limits store no scan of what lies inside them: rebuild with rake seaports:geometry"
  end

  def selection(accepts)
    { "locode" => "NLRTM", "reviewed_at" => "2026-11-23", "features" => [],
      "port_limits" => { "derive" => "hull", "note" => "n", "accepts" => accepts } }
  end

  def test_accepts_is_checked_offline
    assert Builder.new(selection({ "houses" => 8, "places" => ["Les Neiges"] })).check!
    assert_raises(Builder::Invalid) { Builder.new(selection({ "homes" => 8 })).check! }
    assert_raises(Builder::Invalid) { Builder.new(selection({ "houses" => -1 })).check! }
    assert_raises(Builder::Invalid) { Builder.new(selection({ "places" => "Les Neiges" })).check! }
  end

  # Accepting what a refresh found changes no shape, so it needs no rebuild.
  def test_the_digest_leaves_accepts_out
    without = selection(nil).tap { |s| s["port_limits"].delete("accepts") }

    assert_equal Builder.digest(without), Builder.digest(selection({ "houses" => 8 }))
  end

  def test_the_canonical_form_orders_accepts
    dumped = Seaports::Geometry::Selection.dump(selection({ "places" => ["Les Neiges"], "houses" => 8 }))

    assert_match(/accepts:\n    houses: 8\n    places:\n    - Les Neiges\n/, dumped)
  end
end
