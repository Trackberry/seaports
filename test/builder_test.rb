# frozen_string_literal: true

require "test_helper"

class BuilderTest < Minitest::Test
  HEADERS = "Change,Country,Location,Name,NameWoDiacritics,Subdivision,Status,Function,Date,IATA,Coordinates,Remarks"

  # Shaped like the real code list, small enough to reason about. Each row is
  # here to prove one rule, and the order is deliberately wrong so the sort
  # has something to do.
  SOURCE = <<~CSV
    #{HEADERS}
    ,NZ,TRG,Tauranga,Tauranga,BOP,AI,1-------,0401,,3741S 17610E,
    ,CN,SHA,Shanghai Hongqiao Apt,Shanghai Hongqiao Apt,SH,AS,---4----,1601,SHA,,
    ,AU,BNE,Brisbane,Brisbane,QLD,AI,12345---,0001,BNE,2728S 15301E,
    X,GB,OLD,Retired Port,Retired Port,,RL,1-------,0001,,5130N 00007W,
    ,ES,VLC,Valencia,Valencia,V,AI,1-------,0001,,,
    ,PA,PCN,Panama Canal,Panama Canal,1,RL,--3-----,0001,,,
    ,AU,BNE,Brisbane Duplicate,Brisbane Duplicate,QLD,AI,1-------,0001,,2728S 15301E,
    ,US,,Country Header Row,Country Header Row,,,1-------,,,,
    ,ZZ,NON,,,,,1-------,,,,
  CSV

  def setup
    @rows = Seaports::Builder.new(SOURCE).rows
    @locodes = @rows.map(&:first)
  end

  # Position 1 of UNECE's function string is "port". Everything else is a road
  # terminal, an airport or a postal exchange, and none of them is somewhere a
  # vessel calls.
  def test_keeps_only_entries_unece_classifies_as_ports
    assert_includes @locodes, "NZTRG"
    assert_includes @locodes, "AUBNE"
    refute_includes @locodes, "CNSHA"
    refute_includes @locodes, "PAPCN"
  end

  # "12345---" is a port that is also an airport and a rail terminal. It is
  # still a port.
  def test_keeps_a_port_that_is_also_something_else
    assert_includes @locodes, "AUBNE"
  end

  def test_drops_an_entry_the_release_is_removing
    refute_includes @locodes, "GBOLD"
  end

  # A row with no location code is a country header, and a row with no name
  # cannot answer the only question anyone asks of this table.
  def test_drops_rows_that_cannot_identify_a_place
    assert_equal @locodes.compact.size, @locodes.size
    refute_includes @locodes, "ZZNON"
    refute(@locodes.any? { |locode| locode.length != 5 })
  end

  def test_keeps_the_first_of_a_duplicated_locode
    assert_equal 1, @locodes.count("AUBNE")
    assert_equal "Brisbane", @rows.find { |row| row.first == "AUBNE" }[1]
  end

  def test_sorts_by_locode_so_a_refresh_diff_is_readable
    assert_equal @locodes.sort, @locodes
  end

  # "2728S 15301E" is 27°28' south, 153°01' east — degrees and whole minutes,
  # rounded to the four places the source can actually justify.
  def test_converts_degrees_and_minutes_to_decimal
    _, _, lat, lng = @rows.find { |row| row.first == "AUBNE" }

    assert_in_delta(-27.4667, lat, 0.0001)
    assert_in_delta 153.0167, lng, 0.0001
  end

  def test_leaves_a_port_with_no_published_coordinates_empty
    _, _, lat, lng = @rows.find { |row| row.first == "ESVLC" }

    assert_nil lat
    assert_nil lng
    assert_equal 2, Seaports::Builder.new(SOURCE).located_count
  end

  def test_writes_a_csv_the_lookup_can_read_back
    path = File.join(Dir.mktmpdir, "ports.csv")
    Seaports::Builder.new(SOURCE).write(path)

    assert_equal %w[locode name lat lng], CSV.readlines(path).first
    assert_equal @locodes, CSV.readlines(path).drop(1).map(&:first)
  end

  # The shipped table must be exactly what the builder produces from the
  # release it claims, or the file has been edited by hand and the next
  # refresh will quietly undo it.
  def test_the_shipped_table_matches_its_own_headers
    header = CSV.readlines(Seaports::TABLE_PATH).first

    assert_equal Seaports::Builder::HEADERS, header
  end

  def test_reads_a_release_number_out_of_the_mirrors_datapackage
    package = File.join(Dir.mktmpdir, "datapackage.json")
    File.write(package, JSON.dump("version" => "2025.1.0"))

    assert_equal "2025-1", Seaports::Builder.published_release(package)
  end

  # A wrong release number would be believed. An absent one prompts a look.
  def test_answers_nothing_rather_than_guessing_at_an_unreadable_release
    package = File.join(Dir.mktmpdir, "datapackage.json")
    File.write(package, "not json at all")

    assert_nil Seaports::Builder.published_release(package)
  end
end
