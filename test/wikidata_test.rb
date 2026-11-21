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

  def test_a_single_port_item_is_taken
    candidates, stats = Seaports::Wikidata.candidates([hit("Q1", "IEORK", 51.85, -8.26, port: true)])

    assert_equal ["IEORK", "Wikidata Q1 (port, CC0)"], [candidates.first.locode, candidates.first.source]
    assert_equal({ ambiguous: 0, not_port_typed: 0 }, stats)
  end

  # A town item is a city centre, often inland: not used, and counted.
  def test_a_code_with_no_port_item_is_left_out_and_counted
    candidates, stats = Seaports::Wikidata.candidates([hit("Q1", "IEORK", 51.85, -8.26)])

    assert_empty candidates
    assert_equal 1, stats[:not_port_typed]
  end

  def test_a_port_with_a_town_item_far_away_is_ambiguous
    far = [hit("Q1", "IEORK", 51.9, -8.5), hit("Q2", "IEORK", 53.0, -6.0, port: true)]
    candidates, stats = Seaports::Wikidata.candidates(far)

    assert_empty candidates
    assert_equal 1, stats[:ambiguous]
  end

  def test_a_port_with_a_town_item_within_fifty_kilometres_is_taken
    candidates, = Seaports::Wikidata.candidates([hit("Q1", "IEORK", 51.9, -8.5), hit("Q2", "IEORK", 51.85, -8.27, port: true)])

    assert_equal [51.85, -8.27], candidates.first.then { [_1.lat, _1.lng] }
  end

  def test_port_items_close_together_resolve_to_the_one_nearest_their_centre
    hits = [hit("Q1", "XXAAA", 10.0, 10.0, port: true), hit("Q2", "XXAAA", 10.02, 10.0, port: true), hit("Q3", "XXAAA", 10.04, 10.0, port: true)]
    candidates, = Seaports::Wikidata.candidates(hits)

    assert_equal "Wikidata Q2 (port, CC0)", candidates.first.source
  end

  def test_port_items_far_apart_are_skipped_and_counted
    candidates, stats = Seaports::Wikidata.candidates([hit("Q1", "XXAAA", 10.0, 10.0, port: true), hit("Q2", "XXAAA", 12.0, 10.0, port: true)])

    assert_empty candidates
    assert_equal 1, stats[:ambiguous]
  end

  def test_parses_exponent_notation
    body = JSON.dump("results" => { "bindings" => [binding_for("Q1", "IE ORK", "-8.26E0", "5.185e1", true)] })

    assert_equal [hit("Q1", "IEORK", 51.85, -8.26, port: true)], Seaports::Wikidata.parse(body)
  end

  def fake_sleep
    slept = []
    Seaports::Wikidata.stub(:sleep, ->(seconds) { slept << seconds }) { yield }
    slept
  end

  # A 200 whose JSON is cut off is retried once, and then its prefix is split.
  def test_a_truncated_answer_is_retried_once_then_split
    asked = Hash.new(0)
    http = lambda do |url, _headers|
      prefix = URI.decode_www_form(URI.parse(url).query).to_h["query"][/STRSTARTS\(\?locode, "(\w+)"\)/, 1]
      asked[prefix] += 1
      next [200, '{"results": {"bindings": [{"item"'] if prefix == "I"

      [200, JSON.dump("results" => { "bindings" => prefix == "IE" ? [binding_for("Q1", "IE ORK", -8.26, 51.85, true)] : [] })]
    end
    hits = nil
    fake_sleep { hits = Seaports::Wikidata.fetch_hits(http:, letters: ["I"]) }

    assert_equal ["IEORK"], hits.map(&:locode)
    assert_equal 2, asked["I"], "tried, retried once, then split"
  end

  def test_honours_retry_after_on_a_429
    answers = [[429, "", { "retry-after" => "17" }], [200, JSON.dump("results" => { "bindings" => [] })]]
    slept = fake_sleep { Seaports::Wikidata.fetch_hits(http: ->(*) { answers.shift }, letters: ["I"]) }

    assert_equal [17], slept
  end

  def test_splits_a_letter_that_times_out_into_two_letter_prefixes
    asked = []
    http = lambda do |url, _headers|
      prefix = URI.decode_www_form(URI.parse(url).query).to_h["query"][/STRSTARTS\(\?locode, "(\w+)"\)/, 1]
      asked << prefix
      next [504, "", {}] if prefix == "I"

      [200, JSON.dump("results" => { "bindings" => prefix == "IE" ? [binding_for("Q1", "IE ORK", -8.26, 51.85, true)] : [] })]
    end
    fake_sleep do
      hits = Seaports::Wikidata.fetch_hits(http:, letters: ["I"], retries: 0)

      assert_equal ["IEORK"], hits.map(&:locode)
    end
    assert_equal 27, asked.size
  end
end
