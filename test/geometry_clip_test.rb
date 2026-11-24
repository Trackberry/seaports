# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "open3"
require "seaports/geometry/builder"
require "seaports/geometry/checks"
require "seaports/geometry/extract"
require "seaports/geometry/clip"

# A harbour drawn in metres around Rotterdam's position: the sea to the
# north, the land to the south with a bay cut into it, and a terminal on
# each side of the bay.
#
#        sea (y > 0)
#   ------------+     +-------------  coastline, land on its left
#        [West] | bay | [East]
#               +-----+
#     land            town (behind the bay's head)
module Harbour
  LNG0 = 4.5
  LAT0 = 51.9167
  M_PER_DEGREE = Seaports::Geometry::Planar::M_PER_DEGREE

  module_function

  def at(x, y) = [(LNG0 + (x / (M_PER_DEGREE * Math.cos(LAT0 * Math::PI / 180.0)))).round(7), (LAT0 + (y / M_PER_DEGREE)).round(7)]

  def box(x1, y1, x2, y2) = { "type" => "Polygon", "coordinates" => [[at(x1, y1), at(x2, y1), at(x2, y2), at(x1, y2), at(x1, y1)]] }

  # Walked east to west, so the land is on its left: south of the open
  # coast, and around the bay.
  COASTLINE = [[3000, 0], [500, 0], [500, -1500], [-500, -1500], [-500, 0], [-3000, 0]].map { |x, y| at(x, y) }.freeze
  WEST = box(-900, -1300, -500, -100)
  EAST = box(500, -1300, 900, -100)
  INLAND = box(-1600, -1300, -1300, -1000)
  # A pond on land inside the hull, far from any terminal.
  POND = box(-1150, -1500, -1000, -1400)
  # A terminal whose quay edge is drawn 10 m back from the coastline.
  SETBACK = box(510, -1300, 900, -100)
  # A quay only 20 m deep on the bay's edge, and a basin the selection lists
  # that OpenStreetMap does not map as water, 10 m behind the west quay.
  NARROW = box(-520, -1300, -500, -100)
  BASIN = box(-1300, -1300, -910, -100)

  def water = { "coastline" => [COASTLINE], "areas" => [POND], "skipped" => [] }

  def geos?
    require "rgeo"
    # rgeo installs without GEOS when it is missing at install time.
    RGeo::Geos.capi_supported?
  rescue LoadError
    false
  end
end

class GeometryClipTest < Minitest::Test
  Builder = Seaports::Geometry::Builder
  Planar = Seaports::Geometry::Planar
  include Harbour

  def setup
    return if Harbour.geos?
    # CI installs GEOS (see .github/workflows/ci.yml); a laptop without it
    # skips these rather than failing the whole suite.
    raise "GEOS is not installed: apt-get install libgeos-dev" if ENV["CI"]

    skip "GEOS is not installed: brew install geos"
  end

  def shapes = ->(refs) { { "way/1" => Harbour::WEST, "way/2" => Harbour::EAST, "way/3" => Harbour::INLAND, "way/4" => Harbour::SETBACK,
                                   "way/5" => Harbour::NARROW, "way/6" => Harbour::BASIN }.slice(*refs) }

  def selection(limits = {}, refs: %w[way/1 way/2])
    names = { "way/1" => "West Quay", "way/2" => "East Quay", "way/3" => "Inland Depot", "way/4" => "Setback Quay", "way/5" => "Narrow Quay" }
    {
      "locode" => "NLRTM", "reviewed_at" => "2026-11-23", "position_outside" => "The test harbour is drawn around it.",
      "port_limits" => { "derive" => "hull", "buffer_m" => 300, "note" => "n" }.merge(limits),
      "features" => refs.map { |ref| { "osm" => ref, "kind" => "terminal", "name" => names[ref], "cargo" => ["bulk"], "note" => "n" } }
    }
  end

  def build(limits = { "clip" => "water" }, **options)
    sel = selection(limits, **options)
    tags = ->(refs) { refs.to_h { |ref| [ref, { "name" => sel["features"].find { |f| f["osm"] == ref }&.dig("name") }.compact] } }
    Builder.new(sel, shapes:, water: ->(_bbox) { Harbour.water }, tags:, inside: ->(_bbox) { [] }).build
  end

  def limits(collection) = collection["features"].find { |f| f["properties"]["kind"] == "port_limits" }["geometry"]
  def inside?(geometry, x, y) = Planar.contains?(geometry, *Harbour.at(x, y))

  def test_without_clip_the_hull_takes_in_the_land_between_the_terminals
    hull = limits(build({}))

    assert inside?(hull, 0, -1560), "the town behind the bay's head"
    assert inside?(hull, -1100, -700), "the land behind the west quay"
  end

  # The point of clipping: the concave water between the quays stays in,
  # the land behind them goes, though the hull covers both.
  def test_clipped_limits_follow_the_water_and_leave_the_land_out
    clipped = limits(build)

    assert inside?(clipped, 0, -800), "the bay between the quays"
    assert inside?(clipped, 0, 150), "the sea off the harbour mouth"
    refute inside?(clipped, 0, -1560), "the town behind the bay's head"
    refute inside?(clipped, -1100, -700), "the land behind the west quay"
    refute inside?(clipped, 1100, -700), "the land behind the east quay"
  end

  def test_a_ship_alongside_a_quay_is_inside
    clipped = limits(build)

    assert inside?(clipped, -480, -700), "20 m off the west quay"
    assert inside?(clipped, 480, -700), "20 m off the east quay"
  end

  # The keep margin only bridges between a terminal and the water: where a
  # fence backs onto land (housing, say), none of that land is taken in.
  def test_land_beyond_a_terminals_fence_is_outside_the_limits
    clipped = limits(build)

    refute inside?(clipped, -905, -700), "5 m behind the west quay's fence"
    refute inside?(clipped, -920, -700), "20 m behind the west quay's fence"
    refute inside?(clipped, 920, -700), "20 m behind the east quay's fence"
    refute inside?(clipped, -700, -90), "10 m north of the west quay, on land"
    assert inside?(clipped, -899, -700), "the west quay itself"
  end

  # A quay edge drawn a few metres off the mapped coastline still joins the
  # water: the margin bridges the gap, and no more.
  def test_a_terminal_set_back_from_the_coastline_still_joins_the_water
    clipped = limits(build(refs: %w[way/1 way/4]))

    assert inside?(clipped, 505, -700), "the 10 m gap between the quay and the water"
    assert inside?(clipped, 505, -1250), "the gap, far down the quay"
    assert inside?(clipped, 480, -700), "the bay beside it"
    refute inside?(clipped, 920, -700), "the land behind the set-back quay"
    assert_equal 1, Planar.polygons(clipped).size, "one body of water"
  end

  # The margin is "within 30 m of both": behind a quay narrower than 30 m the
  # land still within 30 m of the water comes in, and no more.
  def test_land_behind_a_narrow_quay_comes_in_only_while_it_is_within_the_margin_of_the_water
    clipped = limits(build(refs: %w[way/5]))

    assert inside?(clipped, -525, -700), "5 m behind a 20 m quay, 25 m from the water"
    refute inside?(clipped, -545, -700), "25 m behind it, 45 m from the water"
  end

  # A basin the selection lists counts as water for the touch check, so it
  # is bridged to like water: a terminal set back from it joins it.
  def test_a_terminal_set_back_from_a_listed_basin_joins_it
    clipped = limits(build({ "clip" => "water", "osm" => "way/6" }, refs: %w[way/1]))

    assert inside?(clipped, -905, -700), "the 10 m gap between the quay and the basin"
    assert_equal 1, Planar.polygons(clipped).size
  end

  def test_the_terminals_are_kept_whole
    collection = build

    collection["features"].select { |f| f["properties"]["kind"] == "terminal" }.each do |terminal|
      Planar.positions(terminal["geometry"]).each { |lng, lat| assert Planar.contains?(limits(collection), lng, lat) }
    end
  end

  # Water that touches no terminal (a pond in a park, a reservoir) is not
  # the port.
  def test_water_cut_off_from_the_terminals_is_dropped
    refute inside?(limits(build), -1075, -1450)
  end

  def test_the_clipped_limits_are_smaller_and_say_how_they_were_made
    plain = build({})
    clipped = build

    assert_operator Planar.area_m2(limits(clipped)), :<, Planar.area_m2(limits(plain)) * 0.8
    properties = clipped["features"].first["properties"]
    assert_equal "water", properties["clip"]
    assert_match "cut to the water", properties["source"]
  end

  def test_the_clipped_collection_passes_its_checks
    result = Seaports::Geometry::Checks.run(build)

    assert result.ok?, result.errors.join("\n")
  end

  # A ship alongside a terminal with no water beside it would be outside the
  # limits: the build names it rather than shipping that.
  def test_refuses_a_terminal_with_no_water_beside_it
    error = assert_raises(Builder::Invalid) { build(refs: %w[way/1 way/3]) }

    assert_match "Inland Depot", error.message
    refute_match "West Quay", error.message
  end

  # A cold store or a yard behind its jetties has no berth to touch the
  # water: inland says so, and the clip keeps it whole, a part of its own.
  def test_an_inland_terminal_is_kept_whole_without_water_beside_it
    sel = selection({ "clip" => "water", "disjoint" => "The depot stands back from the water." }, refs: %w[way/1 way/3])
    sel["features"].last["inland"] = "A depot with no berth."
    tags = ->(refs) { refs.to_h { |ref| [ref, { "name" => sel["features"].find { |f| f["osm"] == ref }["name"] }] } }
    collection = Builder.new(sel, shapes:, water: ->(_bbox) { Harbour.water }, tags:, inside: ->(_bbox) { [] }).build
    depot = collection["features"].find { |f| f["properties"]["name"] == "Inland Depot" }

    assert_equal "A depot with no berth.", depot["properties"]["inland"]
    assert Planar.positions(depot["geometry"]).all? { |lng, lat| Planar.contains?(limits(collection), lng, lat) }
    assert Seaports::Geometry::Checks.run(collection).ok?
  end

  MARINA = Harbour.box(-200, -1400, 200, -1000)

  def build_excluding(entries, extra = {})
    sel = selection({ "clip" => "water", "exclude" => entries })
    more = { "way/7" => MARINA, "way/8" => Harbour.box(-700, -600, -300, -400),
             "way/9" => { "type" => "LineString", "coordinates" => [Harbour.at(0, -1200), Harbour.at(100, -1200)] } }.merge(extra)
    tags = ->(refs) { refs.to_h { |ref| [ref, { "name" => sel["features"].find { |f| f["osm"] == ref }&.dig("name") }.compact] } }
    Builder.new(sel, shapes: ->(refs) { shapes.call(refs).merge(more.slice(*refs)) }, water: ->(_bbox) { Harbour.water }, tags:,
      inside: ->(_bbox) { [] }).build
  end

  # A marina in the bay is not cargo water: excluded, it is out of the
  # limits, and the outline says what was taken out and why.
  def test_an_excluded_area_is_taken_out_of_the_limits
    collection = build_excluding([{ "osm" => "way/7", "why" => "A leisure marina." }])
    props = collection["features"].first["properties"]

    refute inside?(limits(collection), 0, -1200), "the marina is out"
    assert inside?(limits(collection), 0, -600), "the rest of the bay is in"
    assert_equal [{ "osm" => "way/7", "why" => "A leisure marina." }], props["exclude"]
    assert_match "less way 7 (see exclude)", props["source"]
    assert Seaports::Geometry::Checks.run(collection).ok?
  end

  def test_an_exclusion_that_cuts_into_a_terminal_is_refused
    error = assert_raises(Builder::Invalid) { build_excluding([{ "osm" => "way/8", "why" => "Homes." }]) }

    assert_match "would cut into terminal West Quay", error.message
  end

  def test_an_exclusion_must_be_an_area
    error = assert_raises(Builder::Invalid) { build_excluding([{ "osm" => "way/9", "why" => "A line." }]) }

    assert_match "not an area", error.message
  end

  # Two anchorages named alike are two things to keep, and a point counts:
  # an exclusion holding either is refused, by reference.
  def test_an_exclusion_protects_every_feature_by_reference_points_included
    hull = Harbour.box(-1000, -1500, 1000, 0)
    keep = { "anchorage Anchorage (way/1)" => Harbour.box(-300, -400, -100, -200), "anchorage Anchorage (way/2)" => MARINA,
             "terminal Buoy (node/3)" => { "type" => "Point", "coordinates" => Harbour.at(-200, -800) } }
    _, conflicts = Seaports::Geometry::Clip.subtract(hull, [MARINA, Harbour.box(-250, -850, -150, -750)], keep:)

    assert_equal ["anchorage Anchorage (way/2)", "terminal Buoy (node/3)"], conflicts
  end

  def test_an_exclusion_needs_limits_cut_to_the_water
    unclipped = selection({ "exclude" => [{ "osm" => "way/7", "why" => "A marina." }] })

    error = assert_raises(Builder::Invalid) { Builder.new(unclipped).check! }
    assert_match "needs clip: water", error.message
  end

  def test_an_exclusion_says_why_and_moves_the_digest
    plain = selection({ "clip" => "water" })
    excluding = selection({ "clip" => "water", "exclude" => [{ "osm" => "way/7", "why" => "A marina." }] })

    refute_equal Builder.digest(plain), Builder.digest(excluding)
    assert_raises(Builder::Invalid) { Builder.new(selection({ "exclude" => [{ "osm" => "way/7" }] })).check! }
    assert_raises(Builder::Invalid) { Builder.new(selection({ "exclude" => [{ "osm" => "node/7", "why" => "A point." }] })).check! }
    assert_raises(Builder::Invalid) { Builder.new(selection({ "exclude" => [{ "osm" => "way/7", "why" => "A marina.", "buffer_m" => 5 }] })).check! }
  end

  def test_inland_is_a_reason_on_a_terminal
    sel = selection({ "clip" => "water" }, refs: %w[way/1 way/3])
    sel["features"].last["inland"] = true
    assert_raises(Builder::Invalid) { Builder.new(sel).check! }
    sel["features"].last.merge!("inland" => "No berth.", "kind" => "anchorage")
    assert_raises(Builder::Invalid) { Builder.new(sel).check! }
  end

  def test_an_outline_without_clip_is_built_exactly_as_before
    collection = build({})

    refute collection["features"].first["properties"].key?("clip")
    assert_equal "Polygon", limits(collection)["type"]
    assert_equal Planar.convex_hull(limits(collection)["coordinates"].first), limits(collection)["coordinates"].first
  end

  def test_refuses_clip_on_limits_that_are_not_derived
    assert_raises(Builder::Invalid) { Builder.new(selection({ "derive" => nil, "osm" => "way/1", "clip" => "water" })).check! }
    assert_raises(Builder::Invalid) { Builder.new(selection({ "clip" => "land" })).check! }
    assert_raises(Builder::Invalid) { Builder.new(selection({ "disjoint" => "two docks" })).check! }
    assert Builder.new(selection({ "clip" => "water", "disjoint" => "two docks" })).check!
  end
end

# The sea's side of the coastline, on its own.
class GeometryClipSeaTest < Minitest::Test
  include Harbour

  def setup
    skip "GEOS is not installed" unless Harbour.geos? || ENV["CI"]
  end

  def clip(coastline)
    hull = Harbour.box(-1500, -2000, 1500, 500)
    Seaports::Geometry::Clip.new(hull:, terminals: { "West" => Harbour::WEST }, water: { "coastline" => [coastline], "areas" => [] })
  end

  def test_the_sea_is_on_the_coastlines_right
    geometry = clip(Harbour::COASTLINE).geometry

    assert Seaports::Geometry::Planar.contains?(geometry, *Harbour.at(0, 300))
    refute Seaports::Geometry::Planar.contains?(geometry, *Harbour.at(0, -1800))
  end

  # Drawn the wrong way round, the coastline makes the land the sea: the
  # rule is OpenStreetMap's, and the build follows it rather than guessing.
  def test_a_reversed_coastline_swaps_land_and_sea
    geometry = clip(Harbour::COASTLINE.reverse).geometry

    refute Seaports::Geometry::Planar.contains?(geometry, *Harbour.at(0, 300))
    assert Seaports::Geometry::Planar.contains?(geometry, *Harbour.at(-1100, -1800))
  end

  # A mole or a straight beach is often one long segment whose middle lies
  # far outside the box it splits; it must still say which side is sea.
  def test_a_long_coastline_segment_crossing_the_box_still_votes
    geometry = clip([Harbour.at(10_000, -100), Harbour.at(-3000, -100)]).geometry

    assert Seaports::Geometry::Planar.contains?(geometry, *Harbour.at(0, 300))
  end

  # rgeo installs without GEOS when the library is missing at install time:
  # the build says so up front instead of failing on its first geometry.
  def test_refuses_to_clip_when_rgeo_was_built_without_geos
    error = RGeo::Geos.stub(:capi_supported?, false) do
      assert_raises(Seaports::Geometry::Clip::Unavailable) { Seaports::Geometry::Clip.load_geos! }
    end

    assert_match "installed without it", error.message
  end

  def test_no_coastline_and_no_water_leaves_only_the_terminals
    clip = clip([])

    assert_equal ["West"], clip.dry_terminals
  end
end

# The harbour clipped with the collector running at every allocation. The
# first geometry library the build used (ffi-geos) handed out the children of
# a collection without keeping it alive, so GEOS freed them under the build
# and Ruby crashed, reliably on Dakar's coastline. Run in a child process so
# that a regression fails this test instead of killing the suite.
class GeometryClipGcTest < Minitest::Test
  SCRIPT = <<~RUBY
    require "json"
    require "seaports"
    require "seaports/geometry/clip"

    input = JSON.parse($stdin.read)
    clip = Seaports::Geometry::Clip.new(hull: input["hull"], terminals: { "West" => input["terminal"] },
                                        water: { "coastline" => [input["coastline"]], "areas" => [] })
    GC.stress = true
    geometry = clip.geometry
    dry = clip.dry_terminals
    GC.stress = false
    puts [geometry["type"], dry.size].join(" ")
  RUBY

  def setup
    skip "GEOS is not installed" unless Harbour.geos? || ENV["CI"]
  end

  def test_clipping_survives_the_collector_running_at_every_allocation
    input = JSON.generate("hull" => Harbour.box(-1500, -2000, 1500, 500), "terminal" => Harbour::WEST, "coastline" => Harbour::COASTLINE)
    lib = File.expand_path("../lib", __dir__)
    output, error, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup", "-I", lib, "-e", SCRIPT, stdin_data: input)

    assert status.success?, "ruby died (#{status.inspect}) clipping with the collector running:\n#{error.lines.first(6).join}"
    assert_equal "Polygon 0", output.lines.last.strip
  end
end

class GeometryClipChecksTest < Minitest::Test
  Checks = Seaports::Geometry::Checks

  def feature(kind, geometry, **props)
    stored = kind == "port_limits" ? { "inside" => { "houses" => 0 } } : { "osm_tags" => { "name" => props[:name] }.compact }
    { "type" => "Feature", "geometry" => geometry,
      "properties" => { "kind" => kind, "source" => "test", "licence" => "ODbL-1.0", "reviewed_at" => "2026-11-23", "note" => "n",
                        "cargo" => ["bulk"] }.merge(stored).merge(props.transform_keys(&:to_s)) }
  end

  def collection(limits, terminals)
    { "type" => "FeatureCollection", "locode" => "NLRTM", "quays" => [], "attribution" => "© OpenStreetMap",
      "position_outside" => "drawn around it", "features" => [limits] + terminals }
  end

  def two_parts
    { "type" => "MultiPolygon", "coordinates" => [Harbour.box(-1000, -1400, -400, 0)["coordinates"], Harbour.box(400, -1400, 1000, 0)["coordinates"]] }
  end

  def terminals = [feature("terminal", Harbour::WEST, name: "West"), feature("terminal", Harbour::EAST, name: "East")]

  def test_clipped_limits_in_parts_must_say_why
    result = Checks.run(collection(feature("port_limits", two_parts, clip: "water"), terminals))

    assert(result.errors.any? { |line| line.include?("2 separate parts") })
  end

  def test_clipped_limits_in_parts_that_say_why_pass
    result = Checks.run(collection(feature("port_limits", two_parts, clip: "water", disjoint: "Two docks behind locks."), terminals))

    assert result.ok?, result.errors.join("\n")
  end

  def test_limits_in_parts_are_found_by_point_containment
    limits = feature("port_limits", two_parts, clip: "water", disjoint: "Two docks.")
    areas = collection(limits, terminals)

    assert Seaports::Geometry::Planar.contains?(limits["geometry"], *Harbour.at(700, -700))
    refute Seaports::Geometry::Planar.contains?(limits["geometry"], *Harbour.at(0, -700))
    assert Checks.run(areas).warnings.none? { |line| line.include?("outside the port limits") }
  end

  def test_a_terminal_the_clipped_limits_cut_is_an_error
    narrow = Harbour.box(-1000, -1400, -700, 0)
    result = Checks.run(collection(feature("port_limits", narrow, clip: "water"), [feature("terminal", Harbour::WEST, name: "West")]))

    assert(result.errors.any? { |line| line.include?("West: cut by the port limits") })
  end
end

class GeometryOverlapTest < Minitest::Test
  Planar = Seaports::Geometry::Planar
  Checks = Seaports::Geometry::Checks

  # Two L shapes whose boxes overlap and whose areas do not, like two ports
  # along one lagoon.
  L_WEST = { "type" => "Polygon", "coordinates" => [[[0, 0], [3, 0], [3, 1], [1, 1], [1, 3], [0, 3], [0, 0]]] }.freeze
  L_EAST = { "type" => "Polygon", "coordinates" => [[[4, 4], [1.5, 4], [1.5, 3.5], [3.5, 3.5], [3.5, 1.5], [4, 1.5], [4, 4]]] }.freeze

  def test_shapes_whose_boxes_overlap_but_that_do_not_meet_do_not_intersect
    assert Planar.bboxes_overlap?(Planar.bbox(L_WEST), Planar.bbox(L_EAST))
    refute Planar.intersects?(L_WEST, L_EAST)
  end

  def test_crossing_and_nested_shapes_intersect
    crossing = { "type" => "Polygon", "coordinates" => [[[2, -1], [2.5, -1], [2.5, 2], [2, 2], [2, -1]]] }
    nested = { "type" => "Polygon", "coordinates" => [[[0.2, 0.2], [0.5, 0.2], [0.5, 0.5], [0.2, 0.2]]] }

    assert Planar.intersects?(L_WEST, crossing)
    assert Planar.intersects?(L_WEST, nested)
    assert Planar.intersects?(nested, L_WEST)
  end

  def test_a_multipolygon_intersects_through_any_part
    multi = { "type" => "MultiPolygon", "coordinates" => [[[[10, 10], [11, 10], [11, 11], [10, 10]]], L_EAST["coordinates"]] }

    assert Planar.intersects?(multi, { "type" => "Polygon", "coordinates" => [[[3.6, 3.6], [3.9, 3.6], [3.9, 3.9], [3.6, 3.6]]] })
    refute Planar.intersects?(multi, L_WEST)
  end

  def test_limits_whose_boxes_overlap_but_that_do_not_meet_raise_no_warning
    wrap = lambda do |locode, coordinates|
      shifted = coordinates.map { |ring| ring.map { |x, y| [4.4 + (x * 0.05), 51.85 + (y * 0.05)] } }
      { "type" => "FeatureCollection", "locode" => locode, "quays" => [], "attribution" => "©",
        "position_outside" => "test", "features" => [{ "type" => "Feature", "geometry" => { "type" => "Polygon", "coordinates" => shifted },
          "properties" => { "kind" => "port_limits", "source" => "t", "licence" => "ODbL-1.0", "reviewed_at" => "2026-11-23", "note" => "n" } }] }
    end
    mine = wrap.("NLRTM", L_WEST["coordinates"])
    theirs = wrap.("NLVLA", L_EAST["coordinates"])

    assert(Checks.run(mine, others: { "NLVLA" => theirs }).warnings.none? { |line| line.include?("overlap") })
    assert(Checks.run(mine, others: { "NLVLA" => mine.merge("locode" => "NLVLA") }).warnings.any? { |line| line.include?("overlap NLVLA") })
  end
end

class GeometryWaterTest < Minitest::Test
  Water = Seaports::Geometry::Water

  def way(id, tags, points)
    { "type" => "way", "id" => id, "tags" => tags, "geometry" => points.map { |lng, lat| { "lat" => lat, "lon" => lng } } }
  end

  SQUARE = [[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]].freeze

  def test_sorts_coastline_from_water_areas_and_leaves_land_out
    elements = [
      way(1, { "natural" => "coastline" }, [[0, 0], [1, 0]]),
      way(2, { "natural" => "water", "water" => "river" }, SQUARE),
      way(3, { "waterway" => "dock" }, SQUARE),
      way(4, { "landuse" => "harbour" }, SQUARE),
      way(5, { "waterway" => "canal" }, [[0, 0], [1, 1]]),
      way(6, { "natural" => "water", "area" => "no" }, SQUARE)
    ]
    water = Water.classify(elements)

    assert_equal [[[0, 0], [1, 0]]], water["coastline"]
    assert_equal 2, water["areas"].size
    assert_empty water["skipped"]
  end

  # The coastline's direction is the whole of what it says: it must reach
  # Clip as drawn, never turned into an area.
  def test_a_closed_coastline_stays_a_line_in_its_own_direction
    island = way(1, { "natural" => "coastline" }, SQUARE.reverse)

    assert_equal [SQUARE.reverse], Water.classify([island])["coastline"]
  end

  def test_a_broken_water_relation_is_skipped_and_named
    broken = { "type" => "relation", "id" => 9, "tags" => { "natural" => "water" },
               "members" => [{ "type" => "way", "role" => "outer", "geometry" => [{ "lat" => 0, "lon" => 0 }, { "lat" => 1, "lon" => 1 }] }] }

    assert_match "relation/9", Water.classify([broken])["skipped"].first
  end

  def test_asks_overpass_for_the_coastline_and_water_inside_the_box
    asked = nil
    http = lambda do |url, _headers|
      asked = URI.decode_www_form_component(url.split("data=", 2).last)
      [200, JSON.generate({ "elements" => [way(1, { "natural" => "coastline" }, [[0, 0], [1, 0]])] })]
    end
    water = Water.overpass([4.0, 51.9, 4.1, 52.0], http:)

    assert_includes asked, "[bbox:51.9,4.0,52.0,4.1]"
    assert_includes asked, 'way["natural"="coastline"]'
    assert_includes asked, "out geom;"
    assert_equal 1, water["coastline"].size
  end

  def test_reads_the_tags_of_osmiums_opl
    opl = "w12 Tnatural=water,name=Bassin%20%Saint-Gervais Nn1,n2,n3,n1\nn1 x1.0 y49.0\n"

    assert_equal({ "way/12" => { "natural" => "water", "name" => "Bassin Saint-Gervais" } }, Seaports::Geometry::Extract.tags(opl))
  end
end
