# frozen_string_literal: true

require "test_helper"
require "seaports/coordinate_sources"

class CoordinateSourcesTest < Minitest::Test
  Candidate = Seaports::CoordinateSources::Candidate
  SOURCE = "NGA World Port Index (Pub. 150), snapshot 2026-09-29"

  # name, lat, lng as the shipped table has them: nil where UN/LOCODE has none.
  TABLE = {
    "IEORK" => ["Cork", nil, nil],
    "IEROE" => ["Rosslare", nil, nil],
    "IEDUB" => ["Dublin", nil, nil],
    "AUBNE" => ["Brisbane", -27.4667, 153.0167],
    "ESVLC" => ["Valencia", 39.445, -0.318]
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

  # The table shows a port as placed once a row has filled it. A row that
  # fills it is still that row's, not UN/LOCODE's, and regenerates.
  def test_regenerates_a_row_that_filled_the_port_before
    table = TABLE.merge("IEORK" => ["Cork", 51.85, -8.2667])
    result = Seaports::CoordinateSources.select([candidate("IEORK", "51.85", "-8.2667")], table:, supplied: { "IEORK" => [51.85, -8.2667] })

    assert_equal ["IEORK"], result.rows.map(&:first)
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
    table = TABLE.merge("ESXXX" => ["Nowhere", nil, nil])
    result = Seaports::CoordinateSources.select([candidate("IEORK", "10", "10"), candidate("ESXXX", "1", "1")], table:, boundaries:)

    assert_equal ["ESXXX"], result.rows.map(&:first)
    assert_equal 1, result.counts[:off_country]
  end

  def test_writes_sorted_rows_the_builder_reads
    path = File.join(Dir.mktmpdir, "wpi.csv")
    Seaports::CoordinateSources.write(path, select([candidate("IEROE", "52.25", "-6.33"), candidate("IEORK", "51.85", "-8.26")]).rows)

    assert_equal %w[IEORK IEROE], CSV.read(path, headers: true).map { |row| row["locode"] }
    assert_equal({ "IEORK" => [51.85, -8.26], "IEROE" => [52.25, -6.33] }, Seaports::Builder.coordinate_overrides(path))
  end
end
