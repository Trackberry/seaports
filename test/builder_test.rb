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

    assert_equal %w[locode name lat lng subdivision principal_subdivision subdivision_source], CSV.readlines(path).first
    assert_equal @locodes, CSV.readlines(path).drop(1).map(&:first)
  end

  ISO = {
    "3166-2" => [
      { "code" => "NZ-BOP", "name" => "Bay of Plenty", "type" => "Region" },
      { "code" => "AU-QLD", "name" => "Queensland", "type" => "State" },
      { "code" => "AU-NSW", "name" => "New South Wales", "type" => "State" },
      { "code" => "ES-VC", "name" => "Valenciana, Comunidad", "type" => "Autonomous community" },
      { "code" => "ES-V", "name" => "Valencia", "type" => "Province", "parent" => "ES-VC" },
      { "code" => "NL-NH", "name" => "Noord-Holland", "type" => "Province" }
    ]
  }.freeze

  # Places any port it is asked about in +codes+, and remembers being asked.
  class FakeBoundaries
    attr_reader :asked

    def initialize(codes)
      @codes = codes
      @asked = []
    end

    def codes_at(country, lat, lng)
      @asked << [country, lat, lng]
      @codes
    end
  end

  def iso
    Seaports::Subdivisions.parse(JSON.dump(ISO))
  end

  # [subdivision, principal_subdivision, subdivision_source] by locode.
  def subdivisions_by_locode(builder)
    builder.rows.to_h { |row| [row.first, row.last(3)] }
  end

  def test_resolves_each_port_s_subdivision_and_the_principal_one_above_it
    by_locode = subdivisions_by_locode(Seaports::Builder.new(SOURCE, subdivisions: iso))

    assert_equal ["AU-QLD", "AU-QLD", "unlocode"], by_locode["AUBNE"]
    assert_equal ["ES-V", "ES-VC", "unlocode"], by_locode["ESVLC"]
    assert_equal ["NZ-BOP", "NZ-BOP", "unlocode"], by_locode["NZTRG"]
  end

  def test_leaves_subdivisions_empty_without_the_iso_list
    assert(@rows.all? { |row| row.last(3) == [nil, nil, nil] })
  end

  AMSTERDAM = <<~CSV
    #{HEADERS}
    ,NL,AMS,Amsterdam,Amsterdam,,AI,12345---,0001,AMS,5224N 00449E,
  CSV

  # UN/LOCODE gives Amsterdam no subdivision, but it gives a position.
  def test_places_a_port_unlocode_leaves_blank_by_its_coordinates
    boundaries = FakeBoundaries.new(%w[NL-XX NL-NH])
    by_locode = subdivisions_by_locode(Seaports::Builder.new(AMSTERDAM, subdivisions: iso, boundaries:))

    assert_equal ["NL-NH", "NL-NH", "boundaries"], by_locode["NLAMS"], "the first code ISO knows wins"
    assert_equal [["NL", 52.4, 4.8167]], boundaries.asked
  end

  def test_trusts_unlocode_before_the_map
    boundaries = FakeBoundaries.new(%w[AU-NSW])
    by_locode = subdivisions_by_locode(Seaports::Builder.new(SOURCE, subdivisions: iso, boundaries:))

    assert_equal "AU-QLD", by_locode["AUBNE"].first
  end

  def test_a_reviewed_override_wins_over_everything
    builder = Seaports::Builder.new(SOURCE, subdivisions: iso, overrides: { "AUBNE" => "AU-NSW" })

    assert_equal ["AU-NSW", "AU-NSW", "override"], subdivisions_by_locode(builder)["AUBNE"]
  end

  # An override is typed by a person, so a typo stops the build instead of
  # quietly leaving the port unplaced.
  def test_refuses_an_override_that_is_not_an_iso_code
    builder = Seaports::Builder.new(SOURCE, subdivisions: iso, overrides: { "AUBNE" => "AU-XYZ" })

    error = assert_raises(ArgumentError) { builder.rows }
    assert_includes error.message, "AUBNE"
  end

  def test_every_shipped_override_is_a_valid_row
    overrides = Seaports::Builder.overrides

    assert_operator overrides.size, :>=, 100
    assert(overrides.all? { |locode, code| locode.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/) && code.start_with?("#{locode[0, 2]}-") })
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
