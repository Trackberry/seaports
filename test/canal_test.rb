# frozen_string_literal: true

require "test_helper"
require "seaports/canal/builder"
require "seaports/canal/checks"

class CanalPlanarTest < Minitest::Test
  Planar = Seaports::Geometry::Planar

  def square(x, y, size = 1)
    { "type" => "Polygon", "coordinates" => [[[x, y], [x + size, y], [x + size, y + size], [x, y + size], [x, y]]] }
  end

  def test_areas_overlap_when_a_corner_of_either_is_inside_the_other
    assert Planar.overlap?(square(0, 0, 2), square(1, 1))
    assert Planar.overlap?(square(1, 1), square(0, 0, 4)), "one wholly inside the other"
    refute Planar.overlap?(square(0, 0), square(3, 3))
  end

  # A cross: neither has a corner inside the other, but their edges cross.
  def test_areas_overlap_when_only_their_edges_cross
    wide = { "type" => "Polygon", "coordinates" => [[[0, 1], [3, 1], [3, 2], [0, 2], [0, 1]]] }
    tall = { "type" => "Polygon", "coordinates" => [[[1, 0], [2, 0], [2, 3], [1, 3], [1, 0]]] }

    assert Planar.overlap?(wide, tall)
  end

  def test_a_line_is_labelled_on_its_longest_part
    line = { "type" => "MultiLineString", "coordinates" => [[[0, 0], [0.1, 0]], [[5, 5], [5, 6], [5, 7]]] }

    assert_equal [5, 6], Planar.label_point(line)
    assert_equal 5, Planar.positions(line).size
  end
end

class CanalBuilderTest < Minitest::Test
  Builder = Seaports::Canal::Builder
  Checks = Seaports::Canal::Checks

  NORTH = { "type" => "LineString", "coordinates" => [[32.3, 31.2], [32.31, 30.6]] }.freeze
  SOUTH = { "type" => "LineString", "coordinates" => [[32.31, 30.6], [32.56, 29.95]] }.freeze
  ANCHORAGE = { "type" => "Polygon", "coordinates" => [[[32.33, 31.35], [32.34, 31.35], [32.34, 31.36], [32.33, 31.36], [32.33, 31.35]]] }.freeze
  PILOT = { "type" => "Point", "coordinates" => [32.35, 31.355] }.freeze

  def shapes = ->(refs) { { "way/1" => NORTH, "way/2" => SOUTH, "way/3" => ANCHORAGE, "node/4" => PILOT }.slice(*refs) }

  def selection(features = nil, **changes)
    {
      "canal" => "suez", "name" => "Suez Canal", "reviewed_at" => Date.new(2026, 11, 23),
      "ends" => { "north" => "Port Said", "south" => "Suez" },
      "features" => features || [
        { "osm" => "way/3", "kind" => "anchorage", "name" => "C1", "approach" => "north", "note" => "Seamark." },
        { "osm" => ["way/1", "way/2"], "kind" => "waterway", "name" => "Suez Canal", "note" => "Centreline." },
        { "osm" => "node/4", "kind" => "pilot_boarding", "name" => "Port Said", "approach" => "north", "note" => "x" }
      ]
    }.merge(changes.transform_keys(&:to_s))
  end

  def build(sel = selection) = Builder.new(sel, shapes:).build

  def test_builds_the_waterway_first_as_lines_and_keeps_each_anchorages_approach
    collection = build

    assert_equal "suez", collection["canal"]
    assert_equal({ "north" => "Port Said", "south" => "Suez" }, collection["ends"])
    assert_equal %w[waterway anchorage pilot_boarding], collection["features"].map { |f| f["properties"]["kind"] }
    waterway = collection["features"].first
    assert_equal "MultiLineString", waterway["geometry"]["type"]
    assert_equal 2, waterway["geometry"]["coordinates"].size
    assert_equal "north", collection["features"][1]["properties"]["approach"]
    assert_equal "OpenStreetMap way 3", collection["features"][1]["properties"]["source"]
  end

  def test_the_built_collection_passes_its_checks
    result = Checks.run(build, file_id: "suez")

    assert result.ok?, result.errors.join("\n")
  end

  def test_refuses_an_anchorage_with_no_approach
    features = selection["features"].map { |f| f["kind"] == "anchorage" ? f.except("approach") : f }

    error = assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(features)) }
    assert_match "approach", error.message
  end

  def test_refuses_an_anchorage_with_no_name
    features = selection["features"].map { |f| f["kind"] == "anchorage" ? f.except("name") : f }

    assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(features)) }
  end

  def test_refuses_a_second_waterway_or_none
    two = selection["features"] + [{ "osm" => "way/2", "kind" => "waterway", "name" => "Again" }]
    none = selection["features"].reject { |f| f["kind"] == "waterway" }

    assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(two)) }
    assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(none)) }
  end

  def test_refuses_coordinates_and_misspelt_keys
    typed = selection["features"] + [{ "osm" => "way/3", "kind" => "anchorage", "name" => "X", "approach" => "north", "coordinates" => [[32, 31]] }]

    error = assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(typed)) }
    assert_match "coordinates", error.message
    assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(endz: {})) }
  end

  def test_refuses_ends_that_do_not_name_north_and_south
    assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(ends: { "north" => "Port Said" })) }
  end

  def test_a_waterway_made_of_a_node_is_refused
    features = selection["features"].map { |f| f["kind"] == "waterway" ? f.merge("osm" => "node/4") : f }

    assert_raises(Seaports::Geometry::Builder::Invalid) { build(selection(features)) }
  end

  def test_the_digest_moves_with_an_approach_and_not_with_a_reload
    moved = selection(selection["features"].map { |f| f["kind"] == "anchorage" ? f.merge("approach" => "south") : f })
    reloaded = Seaports::Geometry::Selection.load(Builder.dump_selection(selection))

    assert_equal Builder.digest(selection), build["selection_digest"]
    assert_equal Builder.digest(selection), Builder.digest(reloaded)
    refute_equal Builder.digest(selection), Builder.digest(moved)
  end

  def test_the_outline_drifts_from_a_selection_it_was_not_built_from
    collection = build
    moved = Marshal.load(Marshal.dump(collection))
    moved["features"][1]["properties"]["approach"] = "south"

    assert_empty Checks.drift(collection, selection)
    refute_empty Checks.drift(moved, selection)
  end

  def port(features)
    { "type" => "FeatureCollection", "locode" => "EGPSD", "quays" => [], "attribution" => "x", "features" => features }
  end

  def limits(ring) = { "type" => "Feature", "properties" => { "kind" => "port_limits", "osm" => [] }, "geometry" => { "type" => "Polygon", "coordinates" => [ring] } }

  # Port Said's C and V areas are the canal's waiting areas: limits that
  # take one in would file the canal's queue as ships at anchor in the port.
  def test_an_anchorage_inside_a_ports_limits_is_an_error
    over = limits([[32.335, 31.3], [32.4, 31.3], [32.4, 31.355], [32.335, 31.355], [32.335, 31.3]])
    clear = limits([[32.0, 31.0], [32.1, 31.0], [32.1, 31.1], [32.0, 31.1], [32.0, 31.0]])

    assert(Checks.run(build, others: { "EGPSD" => port([over]) }).errors.any? { |line| line.include?("overlaps EGPSD's port limits") })
    assert_predicate Checks.run(build, others: { "EGPSD" => port([clear]) }), :ok?
  end

  def test_an_anchorage_a_port_also_lists_is_an_error
    shared = { "type" => "Feature", "properties" => { "kind" => "anchorage", "osm" => ["way/3"] }, "geometry" => ANCHORAGE }
    clear = limits([[32.0, 31.0], [32.1, 31.0], [32.1, 31.1], [32.0, 31.1], [32.0, 31.0]])
    result = Checks.run(build, others: { "EGPSD" => port([clear, shared]) })

    assert(result.errors.any? { |line| line.include?("way/3 is also in EGPSD's outline") })
  end

  def test_limits_wholly_inside_an_anchorage_are_an_error
    inside = limits([[32.332, 31.352], [32.338, 31.352], [32.338, 31.358], [32.332, 31.358], [32.332, 31.352]])

    assert(Checks.run(build, others: { "EGPSD" => port([inside]) }).errors.any? { |line| line.include?("overlaps EGPSD's port limits") })
  end

  # A port's anchorages often lie outside its limits, out at sea.
  def test_an_anchorage_overlapping_a_ports_anchorage_outside_its_limits_is_an_error
    clear = limits([[32.0, 31.0], [32.1, 31.0], [32.1, 31.1], [32.0, 31.1], [32.0, 31.0]])
    theirs = { "type" => "Feature", "properties" => { "kind" => "anchorage", "name" => "Outer", "osm" => ["way/99"] }, "geometry" => ANCHORAGE }

    assert(Checks.run(build, others: { "EGPSD" => port([clear, theirs]) }).errors.any? { |line| line.include?("overlaps EGPSD's anchorage Outer") })
  end

  def test_a_pilot_boarding_place_a_port_also_lists_is_an_error
    clear = limits([[32.0, 31.0], [32.1, 31.0], [32.1, 31.1], [32.0, 31.1], [32.0, 31.0]])
    pilot = { "type" => "Feature", "properties" => { "kind" => "pilot_boarding", "osm" => ["node/4"] }, "geometry" => PILOT }

    assert(Checks.run(build, others: { "EGPSD" => port([clear, pilot]) }).errors.any? { |line| line.include?("node/4 is also in EGPSD's outline") })
  end

  # A port build asks this of every shipped canal, even one with errors of
  # its own, before it writes new limits.
  def test_port_conflicts_are_found_even_when_the_canal_has_other_errors
    collection = build
    collection.delete("attribution")
    over = limits([[32.335, 31.3], [32.4, 31.3], [32.4, 31.355], [32.335, 31.355], [32.335, 31.3]])
    conflicts = Checks.new(collection, others: { "EGPSD" => port([over]) }, file_locode: "suez").port_conflicts

    assert_equal ["anchorage C1 overlaps EGPSD's port limits"], conflicts
  end

  def test_overlapping_anchorages_serving_different_ends_are_an_error
    collection = build
    twin = Marshal.load(Marshal.dump(collection["features"][1]))
    twin["properties"].merge!("name" => "Twin", "approach" => "south", "osm" => ["way/5"])
    collection["features"] << twin

    assert(Checks.run(collection).errors.any? { |line| line.include?("overlap but serve different ends") })
  end

  def test_a_waterway_with_no_lines_is_an_error
    collection = build
    collection["features"].first["geometry"] = { "type" => "MultiLineString", "coordinates" => [] }

    assert(Checks.run(collection).errors.any? { |line| line.include?("no lines") })
  end

  def test_a_waterway_drawn_as_an_area_is_an_error
    collection = build
    collection["features"].first["geometry"] = ANCHORAGE

    assert(Checks.run(collection).errors.any? { |line| line.include?("not a MultiLineString") })
  end

  def test_an_unnamed_anchorage_in_a_shipped_file_is_an_error
    collection = build
    collection["features"][1]["properties"].delete("name")

    assert(Checks.run(collection).errors.any? { |line| line.include?("no name") })
  end

  def test_a_file_named_for_another_canal_is_an_error
    assert(Checks.run(build, file_id: "panama").errors.any? { |line| line.include?("named panama") })
  end
end

# Against the canal outlines the gem ships.
class CanalApiTest < Minitest::Test
  Builder = Seaports::Canal::Builder

  def test_lists_the_canals
    assert_equal %w[panama suez], Seaports.canal_ids
    assert_equal %w[panama suez], Seaports.canals.map(&:id)
  end

  def test_finds_a_canal_whatever_the_case_and_answers_nil_for_an_unknown_one
    assert_equal "Suez Canal", Seaports.canal(" SUEZ ").name
    assert_nil Seaports.canal("kiel")
    assert_nil Seaports.canal("../suez")
  end

  def test_a_ship_off_port_said_is_waiting_at_the_north_end_of_suez
    c1 = Seaports.canal("suez").anchorages.find { |area| area.name == "C1" && area.approach == "north" }
    area = Seaports.canal_anchorage_at(c1.lat, c1.lng)

    assert_equal %w[suez C1 north], [area.canal, area.name, area.approach]
    assert_equal "Port Said", Seaports.canal("suez").end_name(area.approach)
    assert Seaports.canal("suez").waiting?(c1.lat, c1.lng)
  end

  def test_a_ship_mid_ocean_or_mid_channel_is_waiting_for_no_canal
    assert_nil Seaports.canal_anchorage_at(20.0, -40.0)
    assert_nil Seaports.canal_anchorage_at(51.0, 1.5)
  end

  def test_each_canal_has_one_waterway_and_anchorages_at_both_ends
    Seaports.canals.each do |canal|
      assert_equal "MultiLineString", canal.waterway.geometry["type"], canal.id
      %w[north south].each { |approach| refute_empty canal.anchorages_for(approach), "#{canal.id} #{approach}" }
      assert_equal 2, canal.ends.size
    end
  end

  def test_an_unknown_approach_raises
    assert_raises(ArgumentError) { Seaports.canal("suez").anchorages_for(:northbound) }
  end

  def test_every_label_point_is_inside_its_area_and_every_area_is_licensed
    Seaports.canals.flat_map(&:areas).each do |area|
      assert_equal "ODbL-1.0", area.licence
      refute_nil area.lat, "#{area.canal} #{area.name}"
      next if area.point? || area.line?

      assert area.contains?(area.lat, area.lng), "#{area.canal} #{area.name}"
    end
  end

  def test_every_shipped_canal_was_built_from_its_selection_in_canonical_form
    Seaports.canal_ids.each do |id|
      assert Builder.current?(id), "#{id}: rebuild it with rake seaports:geometry[#{id}]"
      text = File.read(Builder.selection_path(id))
      assert_equal Builder.dump_selection(Builder.read_selection(Builder.selection_path(id))), text, "#{id}: not in canonical form"
    end
  end

  # The bug a canal outline exists to prevent.
  def test_no_canal_anchorage_is_inside_a_shipped_ports_limits
    Seaports.canals.flat_map(&:anchorages).each do |area|
      Seaports.geometry_locodes.each do |locode|
        limits = Seaports.port_limits(locode)
        refute Seaports::Geometry::Planar.overlap?(area.geometry, limits.geometry), "#{area.canal} #{area.name} overlaps #{locode}" if limits
      end
    end
  end
end
