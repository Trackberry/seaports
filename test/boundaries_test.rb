# frozen_string_literal: true

require "test_helper"
require "seaports/boundaries"

class BoundariesTest < Minitest::Test
  # Two squares a degree wide, side by side, the left one with a hole, plus a
  # Northern Irish district under a code ISO has retired.
  def square(min_lng, min_lat, size = 1.0)
    [[min_lng, min_lat], [min_lng + size, min_lat], [min_lng + size, min_lat + size], [min_lng, min_lat + size], [min_lng, min_lat]]
  end

  def feature(properties, rings)
    { "type" => "Feature", "properties" => properties, "geometry" => { "type" => "Polygon", "coordinates" => rings } }
  end

  def setup
    geojson = {
      "type" => "FeatureCollection",
      "features" => [
        feature({ "iso_3166_2" => "ES-V", "region_cod" => "ES.VC" }, [square(0.0, 39.0), square(0.3, 39.3, 0.4)]),
        feature({ "iso_3166_2" => "ES-CS", "region_cod" => "ES.VC" }, [square(1.0, 39.0)]),
        feature({ "iso_3166_2" => "GB-LRN", "gu_a3" => "NIR" }, [square(-6.0, 54.8)]),
        feature({ "iso_3166_2" => "-99" }, [square(10.0, 10.0)]),
        feature({ "iso_3166_2" => "NO-55" }, [square(20.0, 69.5)]),
        { "type" => "Feature", "properties" => { "iso_3166_2" => "ES-PM" },
          "geometry" => { "type" => "MultiPolygon", "coordinates" => [[square(2.5, 39.5, 0.5)], [square(4.0, 39.8, 0.3)]] } }
      ]
    }
    @boundaries = Seaports::Boundaries.parse(JSON.dump(geojson))
  end

  # Mallorca and Menorca are one area drawn as two polygons.
  def test_finds_a_point_on_any_polygon_of_a_multipolygon
    assert_equal %w[ES-PM], @boundaries.codes_at("ES", 39.7, 2.7)
    assert_equal %w[ES-PM], @boundaries.codes_at("ES", 39.95, 4.15)
  end

  # Just south of where Valencia and Castellón meet: about 4 km from
  # Valencia's edge and 6 km from Castellón's corner.
  def test_an_offshore_point_goes_to_the_nearer_of_two_areas
    assert_equal "ES-V", @boundaries.codes_at("ES", 38.96, 0.95).first
  end

  # At 70°N a degree of longitude is 38 km, so 8 km east of the coast is
  # 0.21° away: further than a margin sized for latitude would look.
  def test_honours_the_ten_kilometres_in_the_far_north
    assert_equal %w[NO-55], @boundaries.codes_at("NO", 70.0, 21.21)
    assert_empty @boundaries.codes_at("NO", 70.0, 21.4), "15 km out is too far"
  end

  def test_finds_the_subdivision_a_point_is_in
    assert_equal %w[ES-V ES-VC], @boundaries.codes_at("ES", 39.2, 0.2)
    assert_equal %w[ES-CS ES-VC], @boundaries.codes_at("ES", 39.2, 1.5)
  end

  # The middle of the hole is about 17 km from any edge, past the offshore
  # allowance, so nothing claims it.
  def test_a_point_in_a_hole_is_not_in_the_area
    assert_empty @boundaries.codes_at("ES", 39.5, 0.5)
  end

  # A port's position is often its waterfront, a little offshore of the map.
  def test_places_a_point_just_offshore_in_the_nearest_subdivision
    assert_equal "ES-V", @boundaries.codes_at("ES", 38.97, 0.5).first
  end

  def test_leaves_a_point_far_offshore_unplaced
    assert_empty @boundaries.codes_at("ES", 37.0, 0.5)
  end

  def test_searches_only_the_port_s_own_country
    assert_empty @boundaries.codes_at("FR", 39.2, 0.2)
  end

  def test_offers_the_uk_nation_when_the_district_code_is_retired
    assert_equal %w[GB-LRN GB-NIR], @boundaries.codes_at("GB", 55.0, -5.5)
  end

  def test_skips_areas_without_a_code
    assert_empty @boundaries.codes_at("XX", 10.5, 10.5)
  end

  def test_needs_a_position
    assert_empty @boundaries.codes_at("ES", nil, nil)
  end
end
