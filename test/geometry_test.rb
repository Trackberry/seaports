# frozen_string_literal: true

require "test_helper"
require "seaports/geometry/builder"
require "seaports/geometry/checks"
require "seaports/geometry/candidates"
require "seaports/geometry/selection"

class GeometryPlanarTest < Minitest::Test
  Planar = Seaports::Geometry::Planar

  SQUARE = { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]] }.freeze
  FRAME = { "type" => "Polygon", "coordinates" => [
    [[0, 0], [4, 0], [4, 4], [0, 4], [0, 0]],
    [[1, 1], [1, 3], [3, 3], [3, 1], [1, 1]]
  ] }.freeze

  def test_a_point_inside_a_polygon_is_contained
    assert Planar.contains?(SQUARE, 0.5, 0.5)
    refute Planar.contains?(SQUARE, 1.5, 0.5)
  end

  # A dock basin cut out of a terminal: a ship in the water is not on the quay.
  def test_a_point_in_a_hole_is_not_contained
    assert Planar.contains?(FRAME, 0.5, 2)
    refute Planar.contains?(FRAME, 2, 2)
  end

  def test_a_multipolygon_contains_a_point_in_any_part
    both = { "type" => "MultiPolygon", "coordinates" => [SQUARE["coordinates"], [[[5, 5], [6, 5], [6, 6], [5, 6], [5, 5]]]] }

    assert Planar.contains?(both, 5.5, 5.5)
    refute Planar.contains?(both, 3, 3)
  end

  # One degree square at the equator is about 12,364 km².
  def test_area_is_in_square_metres_less_the_holes
    assert_in_delta 12_364, Planar.area_m2(SQUARE) / 1_000_000, 10
    assert_in_delta 12 * 12_364, Planar.area_m2(FRAME) / 1_000_000, 40
  end

  def test_the_convex_hull_closes_and_drops_inner_points
    hull = Planar.convex_hull([[0, 0], [2, 0], [2, 2], [0, 2], [1, 1]])

    assert_equal hull.first, hull.last
    assert_equal 5, hull.size
    refute_includes hull, [1, 1]
  end

  def test_spread_grows_the_hull_by_about_the_distance_asked
    hull = Planar.convex_hull(Planar.spread([[4.0, 52.0]], 1000))
    box = Planar.bbox({ "type" => "Polygon", "coordinates" => [hull] })

    assert_in_delta 2000, Planar.distance_m([box[0], 52.0], [box[2], 52.0]), 20
  end
end

class GeometryOsmTest < Minitest::Test
  Osm = Seaports::Geometry::Osm

  def node(lat, lon) = { "lat" => lat, "lon" => lon }

  # Relations arrive as member ways in any order and direction.
  def test_joins_member_ways_into_rings_whatever_their_direction
    a = [[0, 0], [1, 0], [1, 1]]
    b = [[0, 1], [1, 1]]
    c = [[0, 1], [0, 0]]
    closed, open = Osm.rings([a, b, c])
    ring = closed.first

    assert_equal ring.first, ring.last
    assert_equal 5, ring.size
    assert_equal 0, open
  end

  def test_counts_a_ring_that_never_closes
    assert_equal [[], 1], Osm.rings([[[0, 0], [1, 0], [1, 1]]])
  end

  # Mid-edit breakage: half a terminal must not ship as a small move.
  def test_a_relation_with_an_open_outer_raises
    closed = [node(0, 0), node(0, 1), node(1, 1), node(0, 0)]
    open = [node(5, 5), node(5, 6), node(6, 6)]
    relation = { "type" => "relation", "id" => 7, "members" => [
      { "type" => "way", "role" => "outer", "geometry" => closed },
      { "type" => "way", "role" => "outer", "geometry" => open }
    ] }

    error = assert_raises(Osm::Error) { Osm.shape(relation) }
    assert_match "relation/7", error.message
  end

  # OpenStreetMap lets a hole touch its outer ring, so its first vertex may
  # sit on the boundary.
  def test_a_hole_touching_its_outer_ring_is_kept
    outer = [node(0, 0), node(0, 4), node(4, 4), node(4, 0), node(0, 0)]
    inner = [node(0, 2), node(1, 3), node(2, 2), node(0, 2)]
    shape = Osm.shape({ "type" => "relation", "id" => 8, "members" => [
      { "type" => "way", "role" => "outer", "geometry" => outer },
      { "type" => "way", "role" => "inner", "geometry" => inner }
    ] })

    assert_equal 2, shape["coordinates"].size
  end

  def test_a_reference_with_a_leading_zero_is_refused
    assert_raises(Osm::Error) { Osm.parse_ref("way/0123") }
  end

  # A DNS failure is not a SystemCallError, and must still fail over.
  def test_query_fails_over_after_a_socket_error
    calls = 0
    http = lambda do |url, _headers|
      calls += 1
      raise SocketError, "getaddrinfo" if url.include?("overpass-api.de")

      [200, '{"elements":[]}']
    end

    assert_equal({ "elements" => [] }, Osm.query("[out:json];", http:, pause: ->(_) { }))
    assert_equal 2, calls
  end

  # Overpass answers a timeout with 200 and a remark over partial results.
  def test_query_refuses_a_partial_answer
    partial = JSON.generate({ "elements" => [{ "type" => "node", "id" => 1 }], "remark" => "runtime error: Query timed out in \"query\" at line 1 after 181 seconds." })
    http = ->(_url, _headers) { [200, partial] }

    error = assert_raises(Osm::Error) { Osm.query("[out:json];", http:, pause: ->(_) { }) }
    assert_match "stopped early", error.message
  end

  def test_a_relation_puts_its_inner_ring_inside_the_outer
    outer = [node(0, 0), node(0, 4), node(4, 4), node(4, 0), node(0, 0)]
    inner = [node(1, 1), node(1, 2), node(2, 2), node(1, 1)]
    shape = Osm.shape({ "type" => "relation", "members" => [
      { "type" => "way", "role" => "outer", "geometry" => outer },
      { "type" => "way", "role" => "inner", "geometry" => inner }
    ] })

    assert_equal "Polygon", shape["type"]
    assert_equal 2, shape["coordinates"].size
  end

  def test_an_open_way_comes_back_as_a_line
    shape = Osm.shape({ "type" => "way", "geometry" => [node(0, 0), node(0, 1)] })

    assert_equal "LineString", shape["type"]
  end

  def test_shapes_raises_for_a_feature_openstreetmap_no_longer_has
    http = ->(_url, _headers) { [200, JSON.generate({ "elements" => [] })] }

    error = assert_raises(Osm::Error) { Osm.shapes(["way/1"], http:) }
    assert_match "way/1", error.message
  end

  def test_query_tries_again_after_a_busy_answer
    answers = [[502, "busy"], [502, "busy"], [200, '{"elements":[]}']]
    http = ->(_url, _headers) { answers.shift }

    assert_equal({ "elements" => [] }, Osm.query("[out:json];", http:, pause: ->(_) { }))
  end

  def test_query_gives_up_and_says_why
    http = ->(_url, _headers) { [429, "slow down"] }

    error = assert_raises(Osm::Error) { Osm.query("[out:json];", http:, pause: ->(_) { }) }
    assert_match "429", error.message
  end
end

class GeometryBuilderTest < Minitest::Test
  Builder = Seaports::Geometry::Builder

  # Around Rotterdam's own position (51.9167, 4.5), so the derived limits
  # contain it.
  TERMINAL = { "type" => "Polygon", "coordinates" => [[[4.49, 51.91], [4.51, 51.91], [4.51, 51.92], [4.49, 51.92], [4.49, 51.91]]] }.freeze
  BERTH = { "type" => "LineString", "coordinates" => [[4.495, 51.925], [4.505, 51.925]] }.freeze
  ANCHORAGE = { "type" => "Polygon", "coordinates" => [[[3.8, 52.0], [3.9, 52.0], [3.9, 52.05], [3.8, 52.05], [3.8, 52.0]]] }.freeze
  PILOT = { "type" => "Point", "coordinates" => [3.7, 52.0] }.freeze

  def shapes = ->(refs) { { "way/1" => TERMINAL, "way/2" => BERTH, "way/3" => ANCHORAGE, "node/4" => PILOT }.slice(*refs) }

  # OpenStreetMap's names: each feature's own, as the name rule wants.
  def tags(sel = selection)
    ->(refs) { refs.to_h { |ref| [ref, { "name" => sel["features"].find { |f| Array(f["osm"]).first == ref }&.dig("name") }.compact] } }
  end

  def selection(features = nil)
    {
      "locode" => "NLRTM", "reviewed_at" => Date.new(2026, 11, 23), "quays" => ["NLBOT"],
      "port_limits" => { "derive" => "hull", "buffer_m" => 500, "note" => "No limits in OpenStreetMap." },
      "features" => features || [
        { "osm" => "way/3", "kind" => "anchorage", "name" => "4 East", "category" => "general", "note" => "Seamark." },
        { "osm" => "way/1", "kind" => "terminal", "name" => "Euromax", "operator" => "Hutchison Ports", "cargo" => ["container"], "note" => "x" },
        { "osm" => "way/2", "kind" => "terminal", "name" => "Berth", "buffer_m" => 50, "note" => "A line in OSM." },
        { "osm" => "node/4", "kind" => "pilot_boarding", "name" => "Maas Center", "note" => "x" }
      ]
    }
  end

  def test_builds_a_feature_collection_with_the_limits_first
    collection = Builder.new(selection, shapes:).build

    assert_equal "FeatureCollection", collection["type"]
    assert_equal ["NLBOT"], collection["quays"]
    assert_equal %w[port_limits anchorage terminal terminal pilot_boarding], collection["features"].map { |f| f["properties"]["kind"] }
  end

  def test_every_feature_says_where_it_came_from_and_under_what_licence
    collection = Builder.new(selection, shapes:).build

    collection["features"].each do |feature|
      assert_equal "ODbL-1.0", feature["properties"]["licence"]
      assert_equal "2026-11-23", feature["properties"]["reviewed_at"]
      refute_empty feature["properties"]["source"]
    end
    assert_equal "OpenStreetMap way 1", collection["features"][2]["properties"]["source"]
  end

  # The limits are derived from the terminals, never from the anchorage or
  # the pilot station out at sea, or the port would cover half the North Sea.
  def test_derived_limits_hold_the_terminals_but_not_what_lies_offshore
    limits = Builder.new(selection, shapes:).build["features"].first
    box = Seaports::Geometry::Planar.bbox(limits["geometry"])

    assert_match "Derived", limits["properties"]["source"]
    assert Seaports::Geometry::Planar.contains?(limits["geometry"], 4.5, 51.915)
    assert_operator box[0], :>, 4.4, "the limits reach west to #{box[0]}, towards the anchorage or the pilot"
  end

  def test_refuses_a_misspelt_key_rather_than_ignoring_it
    typo = selection.merge("port_limits" => { "derive" => "hull", "bufer_m" => 5 })

    error = assert_raises(Builder::Invalid) { Builder.new(typo, shapes:).build }
    assert_match "bufer_m", error.message
  end

  def test_refuses_a_buffer_that_is_not_a_number
    bad = selection.merge("port_limits" => { "derive" => "hull", "buffer_m" => "1.5km" })

    assert_raises(Builder::Invalid) { Builder.new(bad, shapes:).build }
  end

  def test_the_outline_drifts_from_a_selection_it_was_not_built_from
    collection = Builder.new(selection, shapes:).build
    checks = Seaports::Geometry::Checks

    assert_empty checks.drift(collection, selection)

    renamed = Marshal.load(Marshal.dump(collection))
    renamed["features"][2]["properties"]["name"] = "Something else"
    refute_empty checks.drift(renamed, selection)
  end

  # The digest lets a pull request skip fetching a port whose outline was
  # built from its selection as it stands: it must move with anything that
  # could change the outline, and not with a note's line wrapping.
  def test_the_outline_carries_the_digest_of_the_selection_it_was_built_from
    collection = Builder.new(selection, shapes:).build
    rebuffered = selection.merge("port_limits" => selection["port_limits"].merge("buffer_m" => 800))
    reloaded = Seaports::Geometry::Selection.load(Seaports::Geometry::Selection.dump(selection))

    assert_equal Builder.digest(selection), collection["selection_digest"]
    assert_equal Builder.digest(selection), Builder.digest(reloaded), "the same selection read back from its file"
    refute_equal Builder.digest(selection), Builder.digest(rebuffered), "a changed buffer, which the drift check cannot see"
  end

  # The digest covers only the keys a selection may have, so a misspelt one
  # must fail the selection's own checks instead of leaving it current.
  def test_a_selection_with_an_unknown_key_fails_its_offline_checks
    typo = selection.merge("features" => selection["features"].map { |f| f["osm"] == "way/1" ? f.merge("bufer_m" => 800) : f })

    assert_equal Builder.digest(selection), Builder.digest(typo)
    assert Builder.new(selection).check!
    assert_raises(Builder::Invalid) { Builder.new(typo).check! }
  end

  def test_every_shipped_outline_was_built_from_its_selection_as_it_stands
    locodes = Dir[File.join(Seaports::Geometry::DIR, "*.geojson")].map { |path| File.basename(path, ".geojson") }

    refute_empty locodes
    locodes.each { |locode| assert Builder.current?(locode), "#{locode}: rebuild it with rake seaports:geometry[#{locode}]" }
  end

  def test_a_line_becomes_an_area_only_when_given_a_buffer
    features = [{ "osm" => "way/2", "kind" => "terminal", "name" => "Berth" }]

    error = assert_raises(Builder::Invalid) { Builder.new(selection(features), shapes:).build }
    assert_match "buffer_m", error.message
  end

  def test_refuses_a_cargo_type_it_does_not_know
    features = [{ "osm" => "way/1", "kind" => "terminal", "cargo" => ["bananas"] }]

    assert_raises(Builder::Invalid) { Builder.new(selection(features), shapes:).build }
  end

  def test_refuses_coordinates_in_a_selection
    features = [{ "osm" => "way/1", "kind" => "terminal", "coordinates" => [[4, 52]] }]

    error = assert_raises(Builder::Invalid) { Builder.new(selection(features), shapes:).build }
    assert_match "coordinates", error.message
  end

  def test_dump_puts_one_feature_on_each_line
    dumped = Builder.dump(Builder.new(selection, shapes:).build)

    assert_equal 5, dumped.lines.count { |line| line.start_with?('{"type":"Feature"') }
    assert JSON.parse(dumped)
  end

  def test_the_built_collection_passes_its_checks
    result = Seaports::Geometry::Checks.run(Builder.new(selection, shapes:, tags:, inside: ->(_bbox) { [] }).build)

    assert result.ok?, result.errors.join("\n")
  end
end

class GeometryChecksTest < Minitest::Test
  Checks = Seaports::Geometry::Checks

  def collection(features, locode: "NLRTM")
    { "type" => "FeatureCollection", "locode" => locode, "quays" => [], "attribution" => "© OpenStreetMap", "features" => features }
  end

  # Limits carry an empty scan, and a terminal or an anchorage the
  # OpenStreetMap name it is given, as a build stores them.
  def feature(kind, coordinates, **props)
    stored = kind == "port_limits" ? { "inside" => { "houses" => 0 } } : { "osm_tags" => { "name" => props[:name] }.compact }
    { "type" => "Feature", "geometry" => { "type" => "Polygon", "coordinates" => [coordinates] },
      "properties" => { "kind" => kind, "source" => "test", "licence" => "ODbL-1.0", "reviewed_at" => "2026-11-23", "note" => "n" }
        .merge(stored).merge(props.transform_keys(&:to_s)) }
  end

  LIMITS = [[4.4, 51.85], [4.6, 51.85], [4.6, 52.0], [4.4, 52.0], [4.4, 51.85]].freeze
  TERMINAL = [[4.49, 51.91], [4.51, 51.91], [4.51, 51.92], [4.49, 51.92], [4.49, 51.91]].freeze

  def test_limits_that_miss_the_port_are_an_error
    far = [[3.0, 50.0], [3.1, 50.0], [3.1, 50.1], [3.0, 50.1], [3.0, 50.0]]
    result = Checks.run(collection([feature("port_limits", far)]))

    assert(result.errors.any? { |line| line.include?("own position") })
  end

  def test_a_ring_that_crosses_itself_is_an_error
    bowtie = [[4.4, 51.85], [4.6, 52.0], [4.6, 51.85], [4.4, 52.0], [4.4, 51.85]]
    result = Checks.run(collection([feature("port_limits", bowtie)]))

    assert(result.errors.any? { |line| line.include?("crosses itself") })
  end

  def test_an_implausibly_small_terminal_is_an_error
    speck = [[4.5, 51.9], [4.50001, 51.9], [4.50001, 51.90001], [4.5, 51.9]]
    result = Checks.run(collection([feature("port_limits", LIMITS), feature("terminal", speck, name: "Speck", cargo: ["bulk"])]))

    assert(result.errors.any? { |line| line.include?("plausible") })
  end

  def test_gaps_are_warnings_not_errors
    result = Checks.run(collection([feature("port_limits", LIMITS), feature("terminal", TERMINAL, name: "Container terminal")]))

    assert result.ok?, result.errors.join("\n")
    assert_includes result.warnings, "no anchorage mapped"
    assert(result.warnings.any? { |line| line.include?("no cargo type") })
  end

  def test_a_terminal_inside_another_ports_limits_is_an_error
    mine = collection([feature("port_limits", LIMITS), feature("terminal", TERMINAL, name: "T", cargo: ["bulk"])])
    theirs = collection([feature("port_limits", LIMITS)], locode: "NLVLA")
    result = Checks.run(mine, others: { "NLVLA" => theirs })

    assert(result.errors.any? { |line| line.include?("inside NLVLA") })
  end

  def test_a_missing_licence_is_an_error
    limits = feature("port_limits", LIMITS)
    limits["properties"].delete("licence")

    assert(Checks.run(collection([limits])).errors.any? { |line| line.include?("licence is missing") })
  end

  # Antwerp once shipped a quay near Vlissingen, 30 km from its nearest
  # Antwerp terminal, picked from the wrong search.
  def test_a_terminal_far_from_the_ports_others_is_an_error
    far = [[3.75, 51.34], [3.76, 51.34], [3.76, 51.345], [3.75, 51.345], [3.75, 51.34]]
    wide = [[3.7, 51.85], [4.6, 51.85], [4.6, 52.0], [3.7, 52.0], [3.7, 51.85]]
    result = Checks.run(collection([feature("port_limits", wide), feature("terminal", TERMINAL, name: "Near", cargo: ["bulk"]),
      feature("terminal", far, name: "Far", cargo: ["bulk"])]))

    assert(result.errors.any? { |line| line.include?("terminal Far is") && line.include?("km from") })
  end
end

class GeometryCandidatesTest < Minitest::Test
  Candidates = Seaports::Geometry::Candidates

  def test_drops_marinas_and_keeps_terminals_without_their_shapes
    elements = [
      { "type" => "way", "id" => 1, "tags" => { "name" => "Euromax", "industrial" => "port", "fixme" => "x" },
        "bounds" => { "minlat" => 51.9, "minlon" => 4.0, "maxlat" => 51.91, "maxlon" => 4.02 } },
      { "type" => "node", "id" => 2, "lat" => 51.9, "lon" => 4.1, "tags" => { "name" => "Jachthaven X", "seamark:type" => "harbour" } }
    ]
    http = ->(_url, _headers) { [200, JSON.generate({ "elements" => elements })] }
    candidates = Candidates.around(51.9, 4.0, radius_m: 500, http:)

    assert_equal ["way/1"], candidates.map(&:ref)
    assert_equal({ "name" => "Euromax", "industrial" => "port" }, candidates.first.tags)
    assert_in_delta 51.905, candidates.first.lat, 0.001
  end
end

# Against the outlines the gem ships, so a broken file fails here rather than
# on somebody's map.
class GeometryApiTest < Minitest::Test
  def test_lists_the_ports_with_an_outline
    assert_includes Seaports.geometry_locodes, "GBDVR"
  end

  def test_answers_the_port_as_geojson_with_its_attribution
    collection = Seaports.geometry("gbdvr ")

    assert_equal "FeatureCollection", collection["type"]
    assert_match "OpenStreetMap", collection["attribution"]
    assert_predicate collection, :frozen?
  end

  # Antwerp's UN/LOCODE point is the city centre, Rotterdam's on the Nieuwe
  # Maas: only the second is somewhere a ship can be.
  def test_says_whether_the_unlocode_position_is_on_the_water
    assert_equal false, Seaports.position_on_water?("BEANR")
    assert_equal true, Seaports.position_on_water?("NLRTM")
    assert_match "UN/LOCODE places the port", Seaports.position_outside("BEANR")
    assert_nil Seaports.position_on_water?("MZMPM")
    assert_nil Seaports.position_outside("MZMPM")
    assert(Seaports.geometry_locodes.all? { |locode| [true, false].include?(Seaports.position_on_water?(locode)) })
  end

  def test_a_port_with_no_outline_answers_nothing_rather_than_raising
    assert_nil Seaports.geometry("MZMPM")
    assert_empty Seaports.areas("MZMPM")
    assert_empty Seaports.quays("MZMPM")
    refute Seaports.within?("MZMPM", -25.97, 32.55)
    assert_nil Seaports.geometry("not a locode")
  end

  # A misspelt kind would otherwise read exactly like "not inside".
  def test_an_unknown_kind_raises
    assert_raises(ArgumentError) { Seaports.within?("NLRTM", 51.955, 4.03, kind: :terminals) }
  end

  # Callers pass arbitrary codes; only ports with an outline are cached.
  def test_unknown_locodes_do_not_grow_the_cache
    Seaports::Geometry.reset!
    %w[ZZAAA ZZAAB ZZAAC].each { |code| Seaports.areas(code) }
    Seaports.areas("GBDVR")

    assert_equal ["GBDVR"], Seaports::Geometry.instance_variable_get(:@entries).keys
  end

  def test_a_ship_in_dover_harbour_is_within_the_port_and_one_mid_channel_is_not
    assert Seaports.within?("GBDVR", 51.1205, 1.3290, kind: :port_limits)
    refute Seaports.within?("GBDVR", 51.0, 1.5)
    assert_equal ["GBDVR"], Seaports.ports_at(51.1205, 1.3290)
  end

def test_names_the_terminal_a_position_is_in
  assert_equal %w[terminal port_limits], Seaports.areas_at("GBDVR", 51.1256, 1.3315).map(&:kind)
  assert_equal ["Port of Dover - Eastern Docks"], Seaports.areas_at("GBDVR", 51.1256, 1.3315, kind: :terminal).map(&:name)
  assert_includes Seaports.terminals("GBDVR").first.cargo, "ro_ro"
end

# The label of an L-shaped quay must sit on the quay, not in the dock.
def test_every_label_point_is_inside_its_area
  Seaports.geometry_locodes.flat_map { |locode| Seaports.areas(locode) }.reject(&:point?).each do |area|
    assert area.contains?(area.lat, area.lng), "#{area.locode} #{area.kind} #{area.name}"
  end
end

  def test_every_area_carries_its_licence_and_review_date
    Seaports.geometry_locodes.each do |locode|
      Seaports.areas(locode).each do |area|
        assert_equal "ODbL-1.0", area.licence, "#{locode} #{area.name}"
        refute_nil area.reviewed_at
      end
    end
  end
end
