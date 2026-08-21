# frozen_string_literal: true

require "test_helper"

class SeaportsTest < Minitest::Test
  # Ports seen in real production port calls, spread across the continents a
  # tracking feed actually crosses. A table that stopped answering these would
  # be a regression nobody would notice until a shipment page went quiet.
  def test_names_the_ports_a_tracking_feed_asks_about
    { "CNXMG" => "Xiamen Pt", "AUBNE" => "Brisbane", "HKHKG" => "Hong Kong",
      "NZTRG" => "Tauranga", "KRPUS" => "Busan", "ESVLC" => "Valencia",
      "COCTG" => "Cartagena", "ESALG" => "Algeciras", "SGSIN" => "Singapore",
      "NLRTM" => "Rotterdam", "USLAX" => "Los Angeles", "DEHAM" => "Hamburg" }.each do |locode, name|
      assert_equal name, Seaports.name(locode), "expected #{locode} to be #{name}"
    end
  end

  def test_answers_coordinates_where_unece_publishes_them
    point = Seaports.coordinates("AUBNE")

    assert_in_delta(-27.4667, point["lat"], 0.001)
    assert_in_delta 153.0167, point["lng"], 0.001
  end

  # Roughly a third of the table has no position published. That is a fact
  # about the source, not a failure: the name is still worth having, and a map
  # simply draws no marker.
  def test_a_port_with_no_published_position_still_has_a_name
    assert_equal "Valencia", Seaports.name("ESVLC")
    assert_nil Seaports.coordinates("ESVLC")
  end

  def test_is_case_and_whitespace_insensitive
    assert_equal "Brisbane", Seaports.name("  aubne ")
  end

  # Anything that is not shaped like a locode is not one, and guessing would
  # mean answering a question nobody asked.
  def test_refuses_anything_that_is_not_a_locode
    [nil, "", "XMG", "CNXMGX", "CN-XMG", "12345"].each do |input|
      assert_nil Seaports.find(input), "expected #{input.inspect} to resolve to nothing"
    end
  end

  def test_find_returns_the_whole_port
    port = Seaports.find("KRPUS")

    assert_equal "KRPUS", port.locode
    assert_equal "Busan", port.name
    assert_in_delta 35.1, port.coordinates["lat"], 0.1
  end

  # UNECE files the Panama Canal as a road terminal with status RL —
  # unverified — so it is not in a sea-port table and a caller falls back to
  # naming the country. A canal is a waterway rather than a port, and its
  # actual ports are coded separately. Pinned because it is the one code
  # tracking feeds send that this table deliberately does not answer: if a
  # future release reclassifies it, that should be a decision and not a
  # surprise.
  def test_does_not_answer_for_an_entry_unece_does_not_classify_as_a_port
    assert_nil Seaports.find("PAPCN")

    assert_equal "Balboa", Seaports.name("PABLB")
    assert_equal "Cristóbal", Seaports.name("PACTB")
  end

  # CNSHA is Shanghai Hongqiao airport, not the port of Shanghai, which is
  # CNSGH. Getting this backwards would put a container ship at an airport.
  def test_excludes_an_airport_that_shares_a_city_with_a_port
    assert_nil Seaports.find("CNSHA")
    assert_equal "Shanghai", Seaports.name("CNSGH")
  end

  def test_holds_the_whole_published_sea_port_list_not_a_sample
    assert_operator Seaports.count, :>, 15_000
    assert_equal Seaports.count, Seaports.all.size
  end

  # A caller handing the table to a map should not be able to break it for
  # everyone else in the process.
  def test_all_hands_out_a_copy
    Seaports.all.clear

    assert_operator Seaports.count, :>, 15_000
  end

  def test_reports_which_unece_edition_it_carries
    assert_match(/\A\d{4}-[12]\z/, Seaports.data_release)
  end
end
