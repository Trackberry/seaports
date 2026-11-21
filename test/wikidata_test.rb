# frozen_string_literal: true

require "test_helper"
require "seaports/wikidata"

class WikidataTest < Minitest::Test
  def hit(item, locode, lat, lng, port: false)
    Seaports::Wikidata::Hit.new(item:, locode:, lat:, lng:, port:)
  end

  def binding_for(item, locode, lng, lat, port)
    { "item" => { "value" => "http://www.wikidata.org/entity/#{item}" }, "locode" => { "value" => locode },
      "coord" => { "value" => "Point(#{lng} #{lat})" }, "port" => { "value" => port.to_s } }
  end

  def test_parses_a_sparql_answer
    body = JSON.dump("results" => { "bindings" => [binding_for("Q1", "IE ORK", -8.26, 51.85, true), { "item" => { "value" => "x" } }] })

    assert_equal [hit("Q1", "IEORK", 51.85, -8.26, port: true)], Seaports::Wikidata.parse(body)
  end

  def test_a_single_item_is_taken
    candidates, ambiguous = Seaports::Wikidata.candidates([hit("Q1", "IEORK", 51.85, -8.26)])

    assert_equal ["IEORK", "Wikidata Q1 (CC0)"], [candidates.first.locode, candidates.first.source]
    assert_equal 0, ambiguous
  end

  def test_a_port_beats_a_town_even_far_away
    candidates, = Seaports::Wikidata.candidates([hit("Q1", "IEORK", 51.9, -8.5), hit("Q2", "IEORK", 53.0, -6.0, port: true)])

    assert_equal [53.0, -6.0], candidates.first.then { [_1.lat, _1.lng] }
  end

  def test_items_close_together_resolve_to_the_one_nearest_their_centre
    hits = [hit("Q1", "XXAAA", 10.0, 10.0), hit("Q2", "XXAAA", 10.02, 10.0), hit("Q3", "XXAAA", 10.04, 10.0)]
    candidates, = Seaports::Wikidata.candidates(hits)

    assert_equal "Wikidata Q2 (CC0)", candidates.first.source
  end

  def test_items_far_apart_are_skipped_and_counted
    candidates, ambiguous = Seaports::Wikidata.candidates([hit("Q1", "XXAAA", 10.0, 10.0), hit("Q2", "XXAAA", 12.0, 10.0)])

    assert_empty candidates
    assert_equal 1, ambiguous
  end

  def test_splits_a_letter_that_times_out_into_two_letter_prefixes
    asked = []
    http = lambda do |url, _headers|
      prefix = URI.decode_www_form(URI.parse(url).query).to_h["query"][/STRSTARTS\(\?locode, "(\w+)"\)/, 1]
      asked << prefix
      next [504, ""] if prefix == "I"

      [200, JSON.dump("results" => { "bindings" => prefix == "IE" ? [binding_for("Q1", "IE ORK", -8.26, 51.85, true)] : [] })]
    end
    Seaports::Wikidata.stub(:sleep, nil) do
      hits = Seaports::Wikidata.fetch_hits(http:, letters: ["I"], retries: 0)

      assert_equal ["IEORK"], hits.map(&:locode)
    end
    assert_equal 27, asked.size
  end
end
