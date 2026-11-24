# frozen_string_literal: true

require "test_helper"
require "seaports/timezones"

class TimezonesTest < Minitest::Test
  # Two Spanish zones, a French one north of the Madrid square, a Dutch one,
  # and open sea east of Madrid and west of the Canaries.
  ZONE_TAB = <<~TAB
    # tzdb timezone descriptions (deprecated version)
    ES\t+4024-00341\tEurope/Madrid\tSpain (mainland)
    ES\t+2806-01524\tAtlantic/Canary\tCanary Islands
    FR\t+4852+00220\tEurope/Paris
    NL\t+5222+00454\tEurope/Amsterdam
  TAB

  def self.square(min_lng, min_lat, width, height = width)
    [[min_lng, min_lat], [min_lng + width, min_lat], [min_lng + width, min_lat + height], [min_lng, min_lat + height], [min_lng, min_lat]]
  end

  def self.zone(id, *squares)
    { "type" => "Feature", "properties" => { "tzid" => id },
      "geometry" => { "type" => "MultiPolygon", "coordinates" => squares.map { |ring| [ring] } } }
  end

  MAP = JSON.dump("type" => "FeatureCollection", "features" => [
    zone("Europe/Madrid", square(0.0, 39.0, 2.0)),
    zone("Atlantic/Canary", square(-16.0, 28.0, 1.0), square(-14.5, 28.0, 0.5)),
    zone("Europe/Paris", square(0.0, 41.0, 2.0)),
    zone("Europe/Amsterdam", square(4.0, 52.0, 1.0)),
    zone("Etc/GMT", square(2.0, 39.0, 4.0, 2.0)),
    { "type" => "Feature", "properties" => { "tzid" => "Etc/GMT+1" },
      "geometry" => { "type" => "Polygon", "coordinates" => [square(-20.0, 28.0, 4.0, 1.0)] } }
  ])

  def setup
    Seaports::Timezones.load_geos!
    @timezones = Seaports::Timezones.parse(MAP, countries: Seaports::Timezones.countries(ZONE_TAB))
  rescue LoadError
    # CI installs GEOS (see .github/workflows/ci.yml); a laptop without it
    # skips these rather than failing the whole suite.
    raise if ENV["CI"]

    skip "GEOS is not installed: brew install geos"
  end

  def port(locode, lat = nil, lng = nil, path = [])
    Seaports::Timezones::Port.new(locode:, lat:, lng:, path:)
  end

  def test_reads_each_countrys_zones_from_zone_tab
    countries = Seaports::Timezones.countries(ZONE_TAB)

    assert_equal %w[Europe/Madrid Atlantic/Canary], countries["ES"]
    assert_equal %w[Europe/Amsterdam], countries["NL"]
    assert_nil countries["XZ"]
  end

  def test_the_vendored_zone_tab_has_spains_three_zones
    assert_equal %w[Europe/Madrid Africa/Ceuta Atlantic/Canary], Seaports::Timezones.countries["ES"]
  end

  # One zone for the whole country: no position needed, and a position that
  # landed over the border does not move the port.
  def test_a_country_with_one_zone_gives_it_to_every_port
    assert_equal ["Europe/Amsterdam", "country"], @timezones.zone_for("NL", nil, nil)
    assert_equal ["Europe/Amsterdam", "country"], @timezones.zone_for("NL", 40.0, 1.0)
  end

  def test_places_a_port_in_the_zone_its_position_falls_in
    assert_equal ["Europe/Madrid", "map"], @timezones.zone_for("ES", 40.0, 1.0)
    assert_equal ["Atlantic/Canary", "map"], @timezones.zone_for("ES", 28.2, -14.2)
  end

  # 0.2° north of the Madrid square is in France, 22 km from Spain: a border
  # port's coarse position. 1.5° north is 167 km, a wrong position.
  def test_a_position_over_the_border_takes_the_nearest_of_its_countrys_zones
    assert_equal ["Europe/Madrid", "nearest"], @timezones.zone_for("ES", 41.2, 1.0)
    assert_equal [nil, nil], @timezones.zone_for("ES", 42.5, 1.0)
  end

  # An oil terminal past the territorial sea is in an Etc/ zone, and may lie
  # further from its coast than a border port does from its border.
  def test_a_position_out_at_sea_takes_the_nearest_zone_within_the_offshore_reach
    assert_equal ["Europe/Madrid", "nearest"], @timezones.zone_for("ES", 40.0, 3.5)
    assert_equal ["Atlantic/Canary", "nearest"], @timezones.zone_for("ES", 28.5, -17.5)
    assert_equal [nil, nil], @timezones.zone_for("ES", 40.0, 5.9), "3.9 degrees out, 333 km at 40° N, is too far"
  end

  def test_a_country_zone_tab_does_not_list_takes_the_maps_zone_even_at_sea
    assert_equal ["Etc/GMT", "map"], @timezones.zone_for("XZ", 40.0, 3.5)
    assert_equal ["Europe/Paris", "map"], @timezones.zone_for("XZ", 42.0, 1.0)
  end

  def test_a_port_with_no_position_in_a_country_with_several_zones_has_none
    assert_equal [nil, nil], @timezones.zone_for("ES", nil, nil)
  end

  def test_a_zone_is_valid_only_for_its_own_country
    assert @timezones.valid?("ES", "Atlantic/Canary")
    refute @timezones.valid?("ES", "Europe/Paris")
    assert @timezones.valid?("XZ", "Etc/GMT+1")
    refute @timezones.valid?("XZ", "Mars/Olympus_Mons")
  end

  def canary_ports(count)
    Array.new(count) { |index| port("ESC0#{index}", 28.2, -15.9 + (index * 0.1), %w[ES-GC ES-CN]) }
  end

  # Three placed ports of the same subdivision agree, so a fourth with no
  # position is in their zone too, at whichever level of its path they share.
  def test_a_port_with_no_position_takes_the_zone_its_subdivision_agrees_on
    zones = @timezones.assign([*canary_ports(3), port("ESXXX", nil, nil, %w[ES-TF ES-CN])])

    assert_equal ["Atlantic/Canary", "subdivision"], zones["ESXXX"]
    assert_equal ["Atlantic/Canary", "map"], zones["ESC00"]
  end

  def test_two_placed_ports_are_not_enough_to_speak_for_a_subdivision
    zones = @timezones.assign([*canary_ports(2), port("ESXXX", nil, nil, %w[ES-GC ES-CN])])

    assert_equal [nil, nil], zones["ESXXX"]
  end

  def test_a_subdivision_split_between_zones_places_nobody
    ports = [*canary_ports(3), port("ESMAD", 40.0, 1.0, %w[ES-GC ES-CN]), port("ESXXX", nil, nil, %w[ES-GC ES-CN])]

    assert_equal [nil, nil], @timezones.assign(ports)["ESXXX"]
  end

  # A country's single zone says nothing about where its subdivisions are,
  # so it is not counted, and an override is one port's alone.
  def test_only_ports_placed_by_position_speak_for_a_subdivision
    overridden = Array.new(3) { |index| port("ESO0#{index}", nil, nil, %w[ES-GC ES-CN]) }
    overrides = overridden.to_h { |each| [each.locode, "Atlantic/Canary"] }
    zones = @timezones.assign([*overridden, port("ESXXX", nil, nil, %w[ES-GC ES-CN])], overrides:)

    assert_equal ["Atlantic/Canary", "override"], zones["ESO00"]
    assert_equal [nil, nil], zones["ESXXX"]
  end

  # Reported, not changed: most such ports keep their own clock on purpose.
  def test_lists_a_port_placed_in_another_zone_than_the_rest_of_its_subdivision
    stray = port("ESMAD", 40.0, 1.0, %w[ES-GC ES-CN])
    ports = [*canary_ports(3), stray]
    placed = @timezones.assign(ports)

    assert_equal [["ESMAD", "Europe/Madrid", "ES-GC", "Atlantic/Canary"]], @timezones.disagreements(ports, placed)
    assert_empty @timezones.disagreements(canary_ports(4), @timezones.assign(canary_ports(4)))
    assert_empty @timezones.disagreements([*canary_ports(2), stray], @timezones.assign([*canary_ports(2), stray])), "two others are too few"
  end

  def test_an_override_wins_over_the_map
    zones = @timezones.assign([port("ESMAD", 40.0, 1.0)], overrides: { "ESMAD" => "Atlantic/Canary" })

    assert_equal ["Atlantic/Canary", "override"], zones["ESMAD"]
  end

  def test_an_override_outside_the_ports_country_stops_the_build
    error = assert_raises(ArgumentError) { @timezones.assign([port("ESMAD", 40.0, 1.0)], overrides: { "ESMAD" => "Europe/Paris" }) }

    assert_match "not a time zone of ES", error.message
  end
end

class TimezoneOverridesTest < Minitest::Test
  def overrides(text)
    path = File.join(Dir.mktmpdir, "timezone_overrides.csv")
    File.write(path, "locode,timezone,note\n#{text}")
    Seaports::Timezones.overrides(path)
  end

  def test_reads_the_reviewed_rows
    assert_equal({ "AULDH" => "Australia/Lord_Howe" }, overrides(%(auldh,Australia/Lord_Howe,"its own time"\n)))
  end

  def test_a_missing_file_is_no_overrides
    assert_empty Seaports::Timezones.overrides(File.join(Dir.mktmpdir, "none.csv"))
  end

  def test_refuses_rows_a_person_would_have_to_fix
    {
      "ZZ,Europe/Madrid,note\n" => "is not a locode",
      "ESVLC,Madrid,note\n" => "has no valid timezone",
      "ESVLC,Europe/Madrid,\n" => "has no note",
      "ESVLC,Europe/Madrid,a\nESVLC,Europe/Madrid,b\n" => "is listed twice"
    }.each do |text, message|
      error = assert_raises(ArgumentError) { overrides(text) }
      assert_match message, error.message
    end
  end

  # Every shipped row must name a zone of its port's country and say why, so
  # a typo fails here rather than in the next refresh.
  def test_every_shipped_override_is_a_zone_of_its_country_and_in_the_table
    countries = Seaports::Timezones.countries
    Seaports::Timezones.overrides.each do |locode, zone|
      assert_includes countries.fetch(locode[0, 2]), zone, locode
      assert_equal zone, Seaports.timezone(locode), "#{locode}: run rake seaports:apply_timezones"
    end
  end
end
