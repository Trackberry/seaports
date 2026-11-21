# frozen_string_literal: true

require "test_helper"
require "seaports/wpi"
require "stringio"

class WpiTest < Minitest::Test
  HEADER = "OID_,World Port Index Number,Region Name,Main Port Name,Alternate Port Name,UN/LOCODE,Country Code,Latitude,Longitude"

  def csv(rows = 10, cork: true)
    body = (1..rows).map { |n| "#{n},#{n},Region,Port #{n},,IE X#{n.to_s.rjust(2, '0')},Ireland,51.0,-8.0" }
    body << "99,99,Region,Cork,,IE ORK,Ireland,51.85,-8.2667" if cork
    "﻿#{HEADER}\r\n#{body.join("\r\n")}\r\n"
  end

  def gzip(text)
    io = StringIO.new("".b)
    writer = Zlib::GzipWriter.new(io)
    writer.write(text)
    writer.close
    io.string
  end

  def quiet(&)
    result = nil
    capture_io { result = yield }
    result
  end

  HTML = "<!DOCTYPE html><html><title>Maritime Safety Information</title></html>"

  # Answers by URL, in the shape of Seaports::Http.get. Records what was asked.
  def http(answers)
    asked = []
    callable = lambda do |url, _headers = {}|
      asked << url
      key = answers.keys.find { |prefix| url.start_with?(prefix) }
      key ? answers.fetch(key) : [404, "".b]
    end
    [callable, asked]
  end

  CDX = Seaports::Wpi::CDX_URL
  ARCHIVE = "https://web.archive.org/web/20260929232408id_/"

  def cdx_answer(*timestamps)
    [200, JSON.dump([%w[timestamp original]] + timestamps.map { |t| [t, Seaports::Wpi::SOURCE_URL] })]
  end

  def test_takes_nga_when_it_answers_with_the_index
    callable, asked = http(Seaports::Wpi::SOURCE_URL => [200, csv.b])
    download = quiet { Seaports::Wpi.fetch_latest(http: callable) }

    assert_equal "NGA", download.via
    assert_equal [Seaports::Wpi::SOURCE_URL], asked
    assert Seaports::Wpi.header?(download.text)
  end

  # NGA's maintenance page is a 200 for some paths and a 503 for others, and
  # is HTML either way.
  def test_falls_back_to_the_internet_archive_when_nga_answers_with_html
    [[200, HTML], [503, HTML]].each do |answer|
      callable, asked = http(Seaports::Wpi::SOURCE_URL => answer, CDX => cdx_answer("20260929232408"),
        "https://web.archive.org/web/20260929232408id_/" => [200, csv.b])
      download = quiet { Seaports::Wpi.fetch_latest(http: callable) }

      assert_equal "the Internet Archive", download.via
      assert_equal "2026-09-29", download.snapshot
      assert_equal 3, asked.size
    end
  end

  def test_decodes_a_gzip_body
    callable, = http(Seaports::Wpi::SOURCE_URL => [503, HTML], CDX => cdx_answer("20260929232408"),
      "https://web.archive.org/web/20260929232408id_/" => [200, gzip(csv)])
    download = quiet { Seaports::Wpi.fetch_latest(http: callable) }

    assert Seaports::Wpi.header?(download.text)
    assert_includes download.text, "IE ORK"
  end

  def test_takes_the_newest_snapshot_that_is_the_index
    callable, = http(Seaports::Wpi::SOURCE_URL => [503, HTML], CDX => cdx_answer("20260101000000", "20260601000000"),
      "https://web.archive.org/web/20260601000000id_/" => [200, HTML.b],
      "https://web.archive.org/web/20260101000000id_/" => [200, csv.b])

    assert_equal "2026-01-01", quiet { Seaports::Wpi.fetch_latest(http: callable) }.snapshot
  end

  def test_is_unavailable_when_neither_nga_nor_the_archive_has_it
    callable, = http(Seaports::Wpi::SOURCE_URL => [503, HTML], CDX => cdx_answer)

    assert_raises(Seaports::Wpi::Unavailable) { quiet { Seaports::Wpi.fetch_latest(http: callable) } }
  end

  def test_asks_the_archive_once_when_nga_raises
    asked = []
    callable = lambda do |url, _headers = {}|
      asked << url
      raise Timeout::Error if url == Seaports::Wpi::SOURCE_URL

      url.start_with?(CDX) ? cdx_answer("20260929232408") : [200, csv.b]
    end

    assert_equal "the Internet Archive", quiet { Seaports::Wpi.fetch_latest(http: callable) }.via
    assert_equal 1, asked.count { |url| url.start_with?(CDX) }
  end

  def test_an_archive_that_cannot_be_read_is_unavailable
    callable, = http(Seaports::Wpi::SOURCE_URL => [503, HTML], CDX => [200, "not json"])

    assert_raises(Seaports::Wpi::Unavailable) { quiet { Seaports::Wpi.fetch_latest(http: callable) } }
  end

  def test_a_truncated_gzip_is_not_the_index
    callable, = http(Seaports::Wpi::SOURCE_URL => [200, gzip(csv).b[0, 120]], CDX => cdx_answer)

    assert_raises(Seaports::Wpi::Unavailable) { quiet { Seaports::Wpi.fetch_latest(http: callable) } }
  end

  def test_rejects_a_file_without_the_columns
    assert_raises(Seaports::Wpi::Invalid) { Seaports::Wpi.validate!("a,b\n1,2\n") }
  end

  def test_rejects_a_file_without_cork
    error = assert_raises(Seaports::Wpi::Invalid) { Seaports::Wpi.validate!(csv(cork: false)) }
    assert_match(/Cork/, error.message)
  end

  def test_rejects_a_file_whose_size_is_off_by_more_than_five_percent
    assert_raises(Seaports::Wpi::Invalid) { Seaports::Wpi.validate!(csv(94), vendored: csv(100)) }
    assert_equal 106, Seaports::Wpi.validate!(csv(105), vendored: csv(100))
    assert_equal 96, Seaports::Wpi.validate!(csv(95), vendored: csv(100))
  end

  # Cut off inside the tolerance, so the row count alone would pass it.
  def test_rejects_a_file_whose_last_row_is_short
    text = csv(100)
    cut = text.sub(/,Ireland,51\.85,-8\.2667\r\n\z/, ",Ire")

    assert_operator Seaports::Wpi.rows(cut).size, :>=, 100
    error = assert_raises(Seaports::Wpi::Invalid) { Seaports::Wpi.validate!(cut, vendored: text) }
    assert_match(/truncated/, error.message)
  end

  def test_candidates_read_the_spaced_locode
    cork = Seaports::Wpi.candidates(csv, source: "s").find { |candidate| candidate.name == "Cork" }

    assert_equal ["IEORK", "51.85", "-8.2667"], [cork.locode, cork.lat, cork.lng]
  end

  def test_the_vendored_index_is_valid
    assert_operator Seaports::Wpi.validate!(File.read(Seaports::Wpi::CSV_PATH)), :>, 3000
    assert_equal Seaports::Wpi.sha256(File.read(Seaports::Wpi::CSV_PATH)), Seaports::Wpi.provenance["sha256"]
  end

  # The generated file is the vendored index put through the rules, nothing
  # else: every row's position is the index's, and its source the snapshot's.
  def test_the_generated_coordinates_match_the_vendored_index
    candidates = Seaports::Wpi.candidates(File.read(Seaports::Wpi::CSV_PATH), source: "x").group_by(&:locode)
    label = Seaports::Wpi.source_label(Seaports::Wpi.provenance.fetch("snapshot"))
    rows = CSV.read(Seaports::Builder::WPI_COORDINATES_PATH, headers: true)

    assert_operator rows.size, :>, 1000
    rows.each do |row|
      candidate = candidates.fetch(row["locode"]).first
      assert_equal [candidate.lat.to_f.round(4), candidate.lng.to_f.round(4)], [row["lat"].to_f, row["lng"].to_f], row["locode"]
      assert_equal label, row["source"]
    end
  end
end
