# frozen_string_literal: true

require "test_helper"
require "seaports/subdivisions"

class SubdivisionsTest < Minitest::Test
  # Shaped like Debian's iso-codes file, with the hierarchies a port lookup
  # meets: a German state with no parent, an English county inside a nation,
  # a Spanish province inside an autonomous community, and a loop that should
  # never exist upstream.
  LIST = {
    "3166-2" => [
      { "code" => "DE-HH", "name" => "Hamburg", "type" => "Land" },
      { "code" => "GB-ENG", "name" => "England", "type" => "Country" },
      { "code" => "GB-SFK", "name" => "Suffolk", "type" => "Two-tier county", "parent" => "GB-ENG" },
      { "code" => "ES-VC", "name" => "Valenciana, Comunidad", "type" => "Autonomous community" },
      { "code" => "ES-V", "name" => "Valencia", "type" => "Province", "parent" => "ES-VC" },
      { "code" => "XX-A", "name" => "Loop A", "type" => "Region", "parent" => "XX-B" },
      { "code" => "XX-B", "name" => "Loop B", "type" => "Region", "parent" => "XX-A" }
    ]
  }.freeze

  def setup
    @subdivisions = Seaports::Subdivisions.parse(JSON.dump(LIST))
  end

  def test_joins_a_locode_subdivision_to_its_country
    assert_equal "DE-HH", @subdivisions.code("DE", "HH")
    assert_equal "GB-SFK", @subdivisions.code("gb", " sfk ")
  end

  # UN/LOCODE carries a few codes ISO never had. Passing one on would hand a
  # holiday calendar a region it cannot read.
  def test_refuses_a_code_iso_does_not_have
    assert_nil @subdivisions.code("DE", "XX")
    assert_nil @subdivisions.code("DE", "")
    assert_nil @subdivisions.code("DE", nil)
  end

  def test_a_top_level_subdivision_is_its_own_principal
    assert_equal "DE-HH", @subdivisions.principal("DE-HH")
  end

  def test_climbs_from_a_county_to_its_nation
    assert_equal "GB-ENG", @subdivisions.principal("GB-SFK")
    assert_equal "ES-VC", @subdivisions.principal("ES-V")
  end

  def test_gives_up_on_a_loop_rather_than_spinning
    assert_nil @subdivisions.principal("XX-A")
  end

  def test_nil_in_nil_out
    assert_nil @subdivisions.principal(nil)
  end
end
