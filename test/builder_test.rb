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

    assert_equal %w[locode name lat lng subdivision principal_subdivision subdivision_path subdivision_source coordinate_source alternate_names], CSV.readlines(path).first
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
    builder.rows.to_h { |row| [row.first, row.values_at(4, 5, 7)] }
  end

  def test_resolves_each_port_s_subdivision_and_the_principal_one_above_it
    by_locode = subdivisions_by_locode(Seaports::Builder.new(SOURCE, subdivisions: iso))

    assert_equal ["AU-QLD", "AU-QLD", "unlocode"], by_locode["AUBNE"]
    assert_equal ["ES-V", "ES-VC", "unlocode"], by_locode["ESVLC"]
    assert_equal ["NZ-BOP", "NZ-BOP", "unlocode"], by_locode["NZTRG"]
  end

  def test_writes_the_whole_path_most_specific_first
    rows = Seaports::Builder.new(SOURCE, subdivisions: iso).rows

    assert_equal "ES-V ES-VC", rows.find { |row| row.first == "ESVLC" }[6]
    assert_equal "AU-QLD", rows.find { |row| row.first == "AUBNE" }[6]
  end

  # Valencia's province is filed under a community the list does not hold.
  # A code with no trustworthy top is dropped rather than shipped half-placed.
  def test_drops_a_code_whose_chain_breaks
    broken = Seaports::Subdivisions.parse(JSON.dump("3166-2" => [
      { "code" => "ES-V", "name" => "Valencia", "type" => "Province", "parent" => "ES-VC" }
    ]))
    rows = Seaports::Builder.new(SOURCE, subdivisions: broken).rows

    assert_equal [nil, nil, nil, nil], rows.find { |row| row.first == "ESVLC" }[4, 4]
  end

  def test_leaves_subdivisions_empty_without_the_iso_list
    assert(@rows.all? { |row| row[4, 4] == [nil, nil, nil, nil] })
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

  # The shipped table was built with the shipped overrides, so every override
  # must show up in it, as the port's subdivision, from that source. This is
  # also what proves each override is a valid ISO code without fetching the
  # ISO list in a test.
  def test_every_shipped_override_is_in_the_shipped_table
    overrides = Seaports::Builder.overrides
    table = CSV.read(Seaports::TABLE_PATH, headers: true).to_h { |row| [row["locode"], row] }

    assert_operator overrides.size, :>=, 100
    overrides.each do |locode, code|
      assert_equal [code, "override"], table.fetch(locode).values_at("subdivision", "subdivision_source"), locode
    end
  end

  def overrides_file(body)
    path = File.join(Dir.mktmpdir, "overrides.csv")
    File.write(path, "locode,subdivision,note\n#{body}")
    path
  end

  def test_reads_an_overrides_file
    assert_equal({ "ESVLC" => "ES-V" }, Seaports::Builder.overrides(overrides_file("esvlc, es-v ,reviewed\n")))
  end

  def test_refuses_an_override_row_with_no_subdivision
    error = assert_raises(ArgumentError) { Seaports::Builder.overrides(overrides_file("ESVLC,,forgot\n")) }
    assert_match(/:2: ESVLC has no subdivision/, error.message)
  end

  def test_refuses_a_port_listed_twice
    error = assert_raises(ArgumentError) { Seaports::Builder.overrides(overrides_file("ESVLC,ES-V,\nESVLC,ES-A,\n")) }
    assert_match(/:3: ESVLC is listed twice/, error.message)
  end

  def test_refuses_a_row_that_is_not_a_locode
    assert_raises(ArgumentError) { Seaports::Builder.overrides(overrides_file("Valencia,ES-V,\n")) }
  end

  # An override wins over everything, so one that has outlived its reason
  # must be pointed out rather than left to mask better data.
  def test_reports_overrides_that_have_outlived_their_reason
    overrides = { "AUBNE" => "AU-QLD", "NZTRG" => "NZ-BOP", "ZZGNE" => "AU-NSW" }
    report = Seaports::Builder.new(SOURCE, subdivisions: iso, overrides:).override_report

    assert_includes report, "`ZZGNE` is overridden but no longer a UN/LOCODE sea port: remove its row."
    assert_includes report, "`AUBNE` now has a UN/LOCODE subdivision (the same code): its override can go."
    assert_equal 3, report.size
  end

  def test_reports_an_override_unlocode_now_contradicts
    report = Seaports::Builder.new(SOURCE, subdivisions: iso, overrides: { "AUBNE" => "AU-NSW" }).override_report

    assert_equal ["`AUBNE` now has a UN/LOCODE subdivision (AU-QLD, not AU-NSW): its override can go."], report
  end

  def coordinate_file(body)
    path = File.join(Dir.mktmpdir, "coordinates.csv")
    File.write(path, "locode,name,lat,lng,source,note\n#{body}")
    path
  end

  def test_a_coordinate_override_fills_a_missing_position
    builder = Seaports::Builder.new(SOURCE, coordinate_overrides: { "ESVLC" => [39.445, -0.318] })
    _, _, lat, lng = builder.rows.find { |row| row.first == "ESVLC" }

    assert_equal [39.445, -0.318], [lat, lng]
    assert_equal 3, builder.located_count
    assert_empty builder.override_report
  end

  # UN/LOCODE is the source of record: a position it publishes is not replaced,
  # and the override is pointed out for removal instead.
  def test_a_coordinate_override_never_replaces_a_unlocode_position
    builder = Seaports::Builder.new(SOURCE, coordinate_overrides: { "AUBNE" => [-27.4, 153.1] })
    _, _, lat, lng = builder.rows.find { |row| row.first == "AUBNE" }

    assert_in_delta(-27.4667, lat, 0.0001)
    assert_in_delta 153.0167, lng, 0.0001
    assert_equal ["`AUBNE` now has UN/LOCODE coordinates (-27.4667, 153.0167, not -27.4, 153.1): its coordinate override can go."], builder.override_report
  end

  def test_reports_a_coordinate_override_for_a_port_that_left_unlocode
    report = Seaports::Builder.new(SOURCE, coordinate_overrides: { "ZZGNE" => [1.0, 2.0] }).override_report

    assert_equal ["`ZZGNE` has a coordinate override but is no longer a UN/LOCODE sea port: remove its row."], report
  end

  # A reviewed position can place a port on the boundaries map.
  def test_an_overridden_position_places_the_port_on_the_boundaries_map
    boundaries = FakeBoundaries.new(%w[ES-V])
    builder = Seaports::Builder.new(SOURCE.sub(",ES,VLC,Valencia,Valencia,V,", ",ES,VLC,Valencia,Valencia,,"),
      subdivisions: iso, boundaries:, coordinate_overrides: { "ESVLC" => [39.445, -0.318] })

    assert_equal ["ES-V", "ES-VC", "boundaries"], subdivisions_by_locode(builder)["ESVLC"]
    assert_equal [["ES", 39.445, -0.318]], boundaries.asked
  end

  def test_reads_a_coordinate_overrides_file
    path = coordinate_file("esvlc,Valencia,39.44504,-0.3180,port area,\n")

    assert_equal({ "ESVLC" => [39.445, -0.318] }, Seaports::Builder.coordinate_overrides(path))
  end

  def test_refuses_a_coordinate_row_with_no_source
    error = assert_raises(ArgumentError) { Seaports::Builder.coordinate_overrides(coordinate_file("ESVLC,Valencia,39.445,-0.318,,\n")) }
    assert_match(/:2: ESVLC has no source/, error.message)
  end

  def test_refuses_a_coordinate_row_off_the_globe
    ["91,0", "10,181", "x,1", ",1"].each do |pair|
      error = assert_raises(ArgumentError, pair) { Seaports::Builder.coordinate_overrides(coordinate_file("ESVLC,Valencia,#{pair},port area,\n")) }
      assert_match(/:2: ESVLC has no valid lat and lng/, error.message)
    end
  end

  def test_refuses_a_coordinate_port_listed_twice
    rows = "ESVLC,Valencia,39.4,-0.3,a,\nESVLC,Valencia,39.5,-0.3,b,\n"
    error = assert_raises(ArgumentError) { Seaports::Builder.coordinate_overrides(coordinate_file(rows)) }
    assert_match(/:3: ESVLC is listed twice/, error.message)
  end

  def test_refuses_a_coordinate_row_that_is_not_a_locode
    assert_raises(ArgumentError) { Seaports::Builder.coordinate_overrides(coordinate_file("Valencia,Valencia,39.4,-0.3,a,\n")) }
  end

  def test_applies_overrides_to_a_table_without_a_download
    path = File.join(Dir.mktmpdir, "ports.csv")
    Seaports::Builder.new(SOURCE).write(path)

    filled = Seaports::Builder.apply_coordinates(path, { "ESVLC" => [39.445, -0.318], "AUBNE" => [1.0, 2.0] })
    table = CSV.read(path, headers: true).to_h { |row| [row["locode"], row] }

    assert_equal ["ESVLC"], filled
    assert_equal %w[39.445 -0.318], table["ESVLC"].values_at("lat", "lng")
    assert_equal "-27.4667", table["AUBNE"]["lat"], "a UN/LOCODE position is left alone"
    assert_equal Seaports::Builder::HEADERS, CSV.readlines(path).first
  end

  # The shipped table must carry every reviewed position that has a gap to
  # fill, so a row added without running seaports:apply_coordinates fails here.
  # Strict on purpose: when a refresh brings a UN/LOCODE position for an overridden port, or drops the port, this
  # fails on the refresh pull request, so the person merging it removes the row the report names.
  def test_every_shipped_coordinate_override_is_in_the_shipped_table
    overrides = Seaports::Builder.coordinate_overrides
    table = CSV.read(Seaports::TABLE_PATH, headers: true).to_h { |row| [row["locode"], row] }

    assert_operator overrides.size, :>=, 4
    overrides.each do |locode, (lat, lng)|
      assert_equal [lat, lng], table.fetch(locode).values_at("lat", "lng").map(&:to_f), locode
    end
    %w[ESVLC ESALG ESBCN GIGIB].each { |locode| assert_includes overrides, locode }
  end

  def test_the_lookup_answers_with_an_overridden_position
    assert_equal({ "lat" => 39.445, "lng" => -0.318 }, Seaports.coordinates("ESVLC"))
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

  def test_answers_nothing_when_the_datapackage_has_no_version
    package = File.join(Dir.mktmpdir, "datapackage.json")
    File.write(package, JSON.dump("name" => "un-locode"))

    assert_nil Seaports::Builder.published_release(package)
  end

  VERSION_FILE = <<~RUBY
    VERSION = "1.3.0"
    DATA_RELEASE = "2024-2"
    DATA_REFRESHED_ON = "2026-11-02"
  RUBY

  def test_stamps_a_refresh_into_the_version_file
    stamped = Seaports::Builder.stamp_version(VERSION_FILE, version: "1.4.0", release: "2026-1", refreshed_on: "2026-12-01")

    assert_equal <<~RUBY, stamped
      VERSION = "1.4.0"
      DATA_RELEASE = "2026-1"
      DATA_REFRESHED_ON = "2026-12-01"
    RUBY
  end

  # The bug this guards: a refresh with no edition used to leave the last one
  # in place, labelling new data with a release it did not come from.
  def test_a_refresh_with_no_edition_clears_the_previous_one
    stamped = Seaports::Builder.stamp_version(VERSION_FILE, version: "1.4.0", release: nil, refreshed_on: "2026-12-01")

    assert_includes stamped, "DATA_RELEASE = nil"
  end

  def test_a_named_edition_replaces_an_empty_one
    empty = VERSION_FILE.sub('"2024-2"', "nil")
    stamped = Seaports::Builder.stamp_version(empty, version: "1.4.0", release: "2026-1", refreshed_on: "2026-12-01")

    assert_includes stamped, 'DATA_RELEASE = "2026-1"'
  end

  def test_the_real_version_file_can_be_stamped
    path = File.expand_path("../lib/seaports/version.rb", __dir__)
    stamped = Seaports::Builder.stamp_version(File.read(path), version: "9.9.0", release: "2030-1", refreshed_on: "2030-01-01")

    assert_includes stamped, 'VERSION = "9.9.0"'
    assert_includes stamped, 'DATA_RELEASE = "2030-1"'
    assert_includes stamped, 'DATA_REFRESHED_ON = "2030-01-01"'
  end

  # UN/LOCODE, then the hand-written file, then the World Port Index, then
  # Wikidata: each fills only what the ones before it leave empty.
  def test_ranks_the_position_sources
    source = SOURCE.sub(/\n\z/, "\n,IE,ORK,Cork,Cork,,AI,1-------,0001,,,\n,IE,ROE,Rosslare,Rosslare,,AI,1-------,0001,,,\n")
    wpi = { "IEORK" => [1.0, 1.0], "IEROE" => [2.0, 2.0], "AUBNE" => [9.0, 9.0], "ESVLC" => [3.0, 3.0] }
    wikidata = { "IEORK" => [4.0, 4.0], "IEROE" => [5.0, 5.0], "ESVLC" => [6.0, 6.0] }
    builder = Seaports::Builder.new(source, coordinate_overrides: { "ESVLC" => [7.0, 7.0] }, fallback_coordinates: [wpi, wikidata])
    points = builder.rows.to_h { |row| [row.first, row.values_at(2, 3)] }

    assert_equal [-27.4667, 153.0167], points["AUBNE"], "UN/LOCODE wins"
    assert_equal [7.0, 7.0], points["ESVLC"], "then the hand-written file"
    assert_equal [1.0, 1.0], points["IEORK"], "then the World Port Index"
    assert_equal [2.0, 2.0], points["IEROE"]
    assert_empty builder.override_report, "a generated row that is redundant is dropped by regeneration, not reported"
  end

  def test_wikidata_fills_what_the_world_port_index_lacks
    source = SOURCE.sub(/\n\z/, "\n,IE,ORK,Cork,Cork,,AI,1-------,0001,,,\n")
    builder = Seaports::Builder.new(source, fallback_coordinates: [{}, { "IEORK" => [4.0, 4.0] }])

    assert_equal [4.0, 4.0], builder.rows.find { |row| row.first == "IEORK" }.values_at(2, 3)
  end

  def apply(path, layers)
    Seaports::Builder.apply_coordinates(path, layers)
    CSV.read(path, headers: true).to_h { |row| [row["locode"], row] }
  end

  def test_applies_the_best_layer_and_records_its_source
    path = File.join(Dir.mktmpdir, "ports.csv")
    Seaports::Builder.new(SOURCE).write(path)

    table = apply(path, { "override" => { "ESVLC" => [1.0, 1.0] }, "wpi" => { "ESVLC" => [2.0, 2.0] }, "wikidata" => {} })

    assert_equal ["1.0", "1.0", "override"], table["ESVLC"].values_at("lat", "lng", "coordinate_source")
    assert_equal ["-27.4667", "unlocode"], table["AUBNE"].values_at("lat", "coordinate_source")
  end

  # A position that left its file leaves the table, and a changed one is
  # replaced: the intermediate state is asserted, not just the end.
  def test_applies_a_regenerated_position_over_the_one_it_replaces
    path = File.join(Dir.mktmpdir, "ports.csv")
    Seaports::Builder.new(SOURCE, fallback_coordinates: [{ "ESVLC" => [1.0, 1.0] }]).write(path)
    assert_equal ["1.0", "wpi"], apply(path, { "wpi" => { "ESVLC" => [1.0, 1.0] } })["ESVLC"].values_at("lat", "coordinate_source")

    table = apply(path, { "wpi" => { "ESVLC" => [2.0, 2.0] } })
    assert_equal ["2.0", "2.0", "wpi"], table["ESVLC"].values_at("lat", "lng", "coordinate_source"), "the new position replaces the old"

    table = apply(path, { "wpi" => {}, "wikidata" => {} })
    assert_nil table["ESVLC"]["lat"]
    assert_nil table["ESVLC"]["coordinate_source"]
    assert_equal ["-27.4667", "unlocode"], table["AUBNE"].values_at("lat", "coordinate_source"), "UN/LOCODE's position is never touched"
  end

  # W8: what UN/LOCODE published is known from the build, not from the values.
  # A fallback that happens to equal UN/LOCODE's own position is still a
  # fallback, and one that equals a row's position does not make it UN/LOCODE's.
  def test_a_position_equal_to_unlocodes_does_not_change_whose_it_is
    path = File.join(Dir.mktmpdir, "ports.csv")
    Seaports::Builder.new(SOURCE).write(path)

    table = apply(path, { "wpi" => { "AUBNE" => [-27.4667, 153.0167], "ESVLC" => [3.0, 3.0] } })
    assert_equal "unlocode", table["AUBNE"]["coordinate_source"]

    table = apply(path, { "wpi" => { "ESVLC" => [3.0, 3.0] } })
    assert_equal "wpi", table["ESVLC"]["coordinate_source"]
    table = apply(path, { "wikidata" => { "ESVLC" => [3.0, 3.0] } })
    assert_equal "wikidata", table["ESVLC"]["coordinate_source"], "the same values from another source are that source's"
  end

  def test_the_builder_records_the_source_of_each_position
    source = SOURCE.sub(/\n\z/, "\n,IE,ORK,Cork,Cork,,AI,1-------,0001,,,\n")
    builder = Seaports::Builder.new(source, coordinate_overrides: { "ESVLC" => [7.0, 7.0] }, fallback_coordinates: [{ "IEORK" => [1.0, 1.0] }, {}])
    sources = builder.rows.to_h { |row| [row.first, row[8]] }

    assert_equal({ "AUBNE" => "unlocode", "ESVLC" => "override", "IEORK" => "wpi", "NZTRG" => "unlocode" }, sources.compact)
  end

  def alternates(builder)
    builder.rows.to_h { |row| [row.first, row.last] }
  end

  def test_the_builder_writes_alternate_names_best_source_first_without_the_ports_own_name
    layers = [{ "ESVLC" => ["Valence", "Valencia"] }, { "ESVLC" => ["Valenz", "valence", "València"], "AUBNE" => ["Brisbane", "Brizzy"] }]
    builder = Seaports::Builder.new(SOURCE, alternate_names: layers)

    assert_equal "Valence|Valenz", alternates(builder)["ESVLC"], "deduplicated, the main name dropped even with an accent"
    assert_equal "Brizzy", alternates(builder)["AUBNE"]
    assert_nil alternates(builder)["NZTRG"]
  end

  def test_the_builder_reads_a_parenthesized_english_name_only_for_a_port_with_a_position
    source = SOURCE.sub(/\n\z/, "\n,EG,ALY,El Iskandariya (Alexandria),El Iskandariya (Alexandria),,AI,1-------,0001,,3112N 02954E,\n" \
      ",RU,ARM,Arman (Magadan),Arman (Magadan),,AI,1-------,0001,,,\n" \
      ",IN,BOM,Mumbai (ex Bombay),Mumbai (ex Bombay),,AI,1-------,0001,,1857N 07250E,\n")
    names = alternates(Seaports::Builder.new(source))

    assert_equal "Alexandria", names["EGALY"]
    assert_nil names["RUARM"], "a parenthesis can name a place the port is near"
    assert_nil names["INBOM"], "a former name is not read from a parenthesis"
  end

  def test_applies_alternate_names_without_a_download_and_reports_what_changed
    path = File.join(Dir.mktmpdir, "ports.csv")
    Seaports::Builder.new(SOURCE).write(path)

    assert_equal ["ESVLC"], Seaports::Builder.apply_alternate_names(path, [{ "ESVLC" => ["Valence"] }])
    table = CSV.read(path, headers: true).to_h { |row| [row["locode"], row] }
    assert_equal "Valence", table["ESVLC"]["alternate_names"]
    assert_equal "-27.4667", table["AUBNE"]["lat"], "the other columns are kept"
    assert_equal [], Seaports::Builder.apply_alternate_names(path, [{ "ESVLC" => ["Valence"] }])
    assert_equal ["ESVLC"], Seaports::Builder.apply_alternate_names(path, [{}]), "a name that left its file leaves the table"
  end

  def test_the_shipped_table_holds_what_the_alternate_name_files_say
    layers = Seaports::Builder.alternate_name_layers
    table = CSV.read(Seaports::TABLE_PATH, headers: true).to_h { |row| [row["locode"], row] }

    assert_operator layers.last.size, :>, 500
    layers.each do |names_by_locode|
      names_by_locode.each_key do |locode|
        row = table.fetch(locode) { flunk "#{locode} is not in the shipped table" }
        expected = Seaports::AlternateNames.for(locode:, name: row["name"], located: !row["lat"].to_s.empty?, layers:)
        assert_equal expected.join("|"), row["alternate_names"].to_s, locode
      end
    end
  end

  def test_every_generated_position_file_is_valid_and_in_the_shipped_table
    table = CSV.read(Seaports::TABLE_PATH, headers: true).to_h { |row| [row["locode"], row] }
    layers = Seaports::Builder.coordinate_layers

    assert_operator layers["wpi"].size, :>, 1000
    assert_operator layers["wikidata"].size, :>, 50
    layers.each do |name, points|
      points.each do |locode, (lat, lng)|
        row = table.fetch(locode)
        next if row["coordinate_source"] == "unlocode" # UN/LOCODE won; the override report names a redundant hand row

        best = layers.find { |_, other| other.key?(locode) }.first
        assert_equal [best, lat, lng], [row["coordinate_source"], *row.values_at("lat", "lng").map(&:to_f)], "#{locode} (#{name})"
      end
    end
  end
end
