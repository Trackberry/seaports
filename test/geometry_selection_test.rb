# frozen_string_literal: true

require "test_helper"
require "seaports/geometry/builder"
require "seaports/geometry/selection"

class GeometrySelectionTest < Minitest::Test
  Selection = Seaports::Geometry::Selection

  def selection
    { "locode" => "NLRTM", "reviewed_at" => "2026-11-01", "quays" => ["NLBOT"],
      "port_limits" => { "derive" => "hull", "buffer_m" => 1500 },
      "features" => [{ "osm" => "way/1", "kind" => "terminal", "name" => "Euromax", "cargo" => ["container"] }] }
  end

  # A program rewrites these files, so every shipped one must already be in
  # the form it writes, or an edit's pull request would rewrite every line.
  def test_every_shipped_selection_is_in_canonical_form
    paths = Dir[File.join(Seaports::Geometry::Builder::SOURCES_DIR, "*.yml")]

    refute_empty paths
    paths.each do |path|
      text = File.read(path)

      assert_equal Selection.dump(Selection.load(text)), text, "#{File.basename(path)} is not canonical"
    end
  end

  def test_update_sets_the_fields_a_reader_can_correct
    edit = { "op" => "update", "osm" => "way/1", "set" => { "cargo" => ["reefer", "Container"], "operator" => "Hutchison" } }
    result = Selection.apply(selection, [edit], reviewed_at: Date.new(2026, 11, 23))

    assert_equal %w[reefer container], result["features"].first["cargo"]
    assert_equal "Hutchison", result["features"].first["operator"]
    assert_equal "2026-11-23", result["reviewed_at"]
    assert_equal ["container"], selection["features"].first["cargo"], "the original is untouched"
  end

  def test_update_refuses_a_field_that_holds_a_shape
    assert_raises(Selection::Invalid) do
      Selection.apply(selection, [{ "op" => "update", "osm" => "way/1", "set" => { "osm" => "way/9" } }])
    end
  end

  def test_add_takes_only_features_that_were_found
    edit = { "op" => "add", "osm" => "way/2", "kind" => "terminal", "name" => "Cool Port", "cargo" => ["reefer"] }

    assert_raises(Selection::Invalid) { Selection.apply(selection, [edit]) }
    result = Selection.apply(selection, [edit], known_refs: ["way/2"])

    assert_equal "Cool Port", result["features"].last["name"]
  end

  def test_add_refuses_a_feature_already_selected
    edit = { "op" => "add", "osm" => "way/1", "kind" => "terminal" }

    assert_raises(Selection::Invalid) { Selection.apply(selection, [edit], known_refs: ["way/1"]) }
  end

  def test_remove_and_quays
    edits = [{ "op" => "remove", "osm" => "way/1" }, { "op" => "quays", "add" => ["nleur"], "remove" => ["NLBOT"] }]
    result = Selection.apply(selection, edits)

    assert_empty result["features"]
    assert_equal ["NLEUR"], result["quays"]
  end

  def test_refuses_unknown_kinds_cargo_and_edits
    [
      { "op" => "update", "osm" => "way/1", "set" => { "cargo" => ["bananas"] } },
      { "op" => "update", "osm" => "way/1", "set" => { "kind" => "port_limits" } },
      { "op" => "update", "osm" => "way/9", "set" => { "name" => "x" } },
      { "op" => "draw", "coordinates" => [[4, 52]] }
    ].each do |edit|
      assert_raises(Selection::Invalid, edit.inspect) { Selection.apply(selection, [edit]) }
    end
  end

  def test_text_is_one_short_line
    long = "Line one\nline two #{'x' * 900}"
    result = Selection.apply(selection, [{ "op" => "update", "osm" => "way/1", "set" => { "note" => long } }])
    note = result["features"].first["note"]

    refute_includes note, "\n"
    assert_operator note.length, :<=, 600
  end

  def test_dump_round_trips
    assert_equal selection, Selection.load(Selection.dump(selection))
  end
end
