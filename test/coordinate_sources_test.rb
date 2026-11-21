# frozen_string_literal: true

require "test_helper"
require "seaports/coordinate_sources"

class CoordinateSourcesTest < Minitest::Test
  Candidate = Seaports::CoordinateSources::Candidate
  SOURCE = "NGA World Port Index (Pub. 150), snapshot 2026-09-29"

  # name, lat, lng, coordinate_source as the shipped table has them.
  TABLE = {
    "IEORK" => ["Cork", nil, nil, nil],
    "IEROE" => ["Rosslare", nil, nil, nil],
    "IEDUB" => ["Dublin", nil, nil, nil],
    "AUBNE" => ["Brisbane", -27.4667, 153.0167, "unlocode"],
    "ESVLC" => ["Valencia", 39.445, -0.318, "override"]
  }.freeze

  def candidate(locode, lat, lng, name: "x")
    Candidate.new(locode:, name:, lat:, lng:, source: SOURCE)
  end

  def select(candidates, **options)
    Seaports::CoordinateSources.select(candidates, table: TABLE, **options)
  end

  def test_adds_a_valid_row_for_a_port_without_a_position
    result = select([candidate("IE ORK", "51.8503", "-8.2667")])

    assert_equal [["IEORK", "Cork", 51.8503, -8.2667, SOURCE]], result.rows
    assert_equal 1, result.counts[:kept]
  end

  def test_rounds_as_the_builder_does
    assert_equal [51.85, -8.2667], select([candidate("IEORK", "51.8500041", "-8.26667")]).rows.first.values_at(2, 3)
  end

  def test_keeps_an_existing_unlocode_position
    result = select([candidate("AUBNE", "-27.0", "153.0")])

    assert_empty result.rows
    assert_equal 1, result.counts[:has_unlocode_position]
  end

  # The table says whose a position is. A port a generated row filled stays
  # open to regeneration; one UN/LOCODE placed never is, even when the row's
  # value equals UN/LOCODE's own.
  def test_regenerates_a_row_that_filled_the_port_before
    table = TABLE.merge("IEORK" => ["Cork", 51.85, -8.2667, "wpi"])
    result = Seaports::CoordinateSources.select([candidate("IEORK", "51.85", "-8.2667")], table:)

    assert_equal ["IEORK"], result.rows.map(&:first)
  end

  def test_an_equal_value_does_not_make_a_fallback_unlocodes
    table = TABLE.merge("IEORK" => ["Cork", 51.85, -8.2667, "unlocode"])
    result = Seaports::CoordinateSources.select([candidate("IEORK", "51.85", "-8.2667")], table:)

    assert_empty result.rows
    assert_equal 1, result.counts[:has_unlocode_position]
  end

  def test_a_table_without_the_source_column_counts_its_positions_as_unlocodes
    table = TABLE.merge("IEORK" => ["Cork", 51.85, -8.2667, nil])

    assert_empty Seaports::CoordinateSources.select([candidate("IEORK", "51.9", "-8.3")], table:).rows
  end

  # Another source outranks this one: the hand-written file, or the World Port
  # Index for Wikidata. Its port is not written here.
  def test_leaves_a_port_a_higher_source_places
    result = select([candidate("IEDUB", "53.3", "-6.2")], held: ["IEDUB"])

    assert_empty result.rows
    assert_equal 1, result.counts[:held_by_other_source]
  end

  def test_skips_a_bad_locode_or_coordinate
    bad = [candidate("", "51.8", "-8.2"), candidate("IE", "51.8", "-8.2"), candidate("IEORK", "", ""), candidate("IEROE", "95", "-6"),
      candidate("IEDUB", "53", "-181"), candidate("IEORK", "abc", "-8.2"), candidate("IEORK", "0", "0")]
    result = select(bad)

    assert_empty result.rows
    assert_equal bad.size, result.counts[:invalid]
  end

  # A locode on two ports is ambiguous, and neither is a better guess.
  def test_skips_a_duplicate_locode
    result = select([candidate("IEORK", "51.85", "-8.26"), candidate("IE ORK", "51.9", "-8.4"), candidate("IEROE", "52.25", "-6.33")])

    assert_equal ["IEROE"], result.rows.map(&:first)
    assert_equal 1, result.counts[:duplicate]
  end

  def test_skips_a_port_the_table_does_not_have
    result = select([candidate("IEZZZ", "51.85", "-8.26")])

    assert_empty result.rows
    assert_equal 1, result.counts[:not_in_table]
  end

  Country = Struct.new(:answers) do
    def near_country?(country, *) = answers[country]
  end

  def test_skips_a_position_outside_its_country_and_passes_one_the_map_cannot_judge
    boundaries = Country.new({ "IE" => false, "ES" => nil })
    table = TABLE.merge("ESXXX" => ["Nowhere", nil, nil, nil])
    result = Seaports::CoordinateSources.select([candidate("IEORK", "10", "10"), candidate("ESXXX", "1", "1")], table:, boundaries:)

    assert_equal ["ESXXX"], result.rows.map(&:first)
    assert_equal 1, result.counts[:off_country]
    assert_equal 1, result.counts[:unjudged]
  end

  def test_lists_names_that_differ
    result = select([candidate("IEORK", "51.85", "-8.26", name: "Cork"), candidate("IEROE", "52.25", "-6.33", name: "Rosslare Europort"),
      candidate("IEDUB", "53.3", "-6.2", name: "Malahide")])

    assert_equal [["IEDUB", "Malahide", "Dublin"]], result.mismatches
  end

  def test_names_that_differ_only_by_accents_or_saint_do_not_count
    assert Seaports::CoordinateSources.same_place?("Fuglafjørdur", "Fuglafjordur")
    assert Seaports::CoordinateSources.same_place?("Sault Ste Marie", "Sault-Sainte-Marie")
    refute Seaports::CoordinateSources.same_place?("Malahide", "Dublin")
  end

  def test_counts_what_a_regeneration_added_removed_and_moved
    before = { "AAAAA" => [10.0, 10.0], "BBBBB" => [10.0, 10.0], "CCCCC" => [10.0, 10.0] }
    after = { "BBBBB" => [10.0, 10.5], "CCCCC" => [10.0, 10.001], "DDDDD" => [1.0, 1.0] }
    change = Seaports::CoordinateSources.change(before, after)

    assert_equal [%w[DDDDD], %w[AAAAA], %w[BBBBB], 3], [change.added, change.removed, change.moved, change.before_size]
  end

  def test_writes_sorted_rows_the_builder_reads
    path = File.join(Dir.mktmpdir, "wpi.csv")
    Seaports::CoordinateSources.write(path, select([candidate("IEROE", "52.25", "-6.33"), candidate("IEORK", "51.85", "-8.26")]).rows)

    assert_equal %w[IEORK IEROE], CSV.read(path, headers: true).map { |row| row["locode"] }
    assert_equal({ "IEORK" => [51.85, -8.26], "IEROE" => [52.25, -6.33] }, Seaports::Builder.coordinate_overrides(path))
  end
end
