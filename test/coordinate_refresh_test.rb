# frozen_string_literal: true

require "test_helper"
require "seaports/coordinate_refresh"

class CoordinateRefreshTest < Minitest::Test
  Refresh = Seaports::CoordinateRefresh
  HEADER = "OID_,World Port Index Number,Region Name,Main Port Name,Alternate Port Name,UN/LOCODE,Country Code,Latitude,Longitude"

  # Port n sits at (n, n); the table below knows the first +known+ of them.
  def csv(count = 100, cork: true, shift: 0)
    body = (1..count).map { |n| "#{n},#{n},Region,Port #{n},,ZZ #{format('%03d', n)},Zedland,#{(n % 80) + shift},#{n % 170}" }
    body << "999,999,Region,Cork,,IE ORK,Ireland,51.85,-8.2667" if cork
    "#{HEADER}\n#{body.join("\n")}\n"
  end

  def table(count = 100)
    ports = (1..count).to_h { |n| ["ZZ#{format('%03d', n)}", ["Port #{n}", nil, nil, nil]] }
    ports.merge("IEORK" => ["Cork", nil, nil, nil])
  end

  def download(text, snapshot: "2026-09-29")
    Seaports::Wpi::Download.new(text:, url: "https://example.test/pub150", snapshot:, via: "the Internet Archive")
  end

  # A directory standing in for data/sources, and keyword arguments for it.
  def sandbox
    @dir = Dir.mktmpdir
    {
      csv_path: File.join(@dir, "wpi", "UpdatedPub150.csv"), provenance_path: File.join(@dir, "wpi", "provenance.json"),
      coordinates_path: File.join(@dir, "coordinates_wpi.csv"), table: table, held: [], today: Date.new(2026, 11, 21)
    }
  end

  def files(options)
    options.values_at(:csv_path, :provenance_path, :coordinates_path).map { |path| File.exist?(path) ? File.read(path) : nil }
  end

  def test_a_first_run_vendors_the_index_and_writes_the_coordinates_together
    options = sandbox
    outcome = Refresh.refresh_wpi(download: download(csv), **options)

    assert_equal "changed", outcome.status
    csv_text, provenance, coordinates = files(options)
    assert_equal Seaports::Wpi.normalize(csv), csv_text
    assert_equal "2026-09-29", JSON.parse(provenance)["snapshot"]
    assert_equal "2026-11-21", JSON.parse(provenance)["retrieved_on"]
    assert_includes coordinates, "IEORK,Cork,51.85,-8.2667,\"NGA World Port Index (Pub. 150), snapshot 2026-09-29\""
    assert_match(/101 ports placed \(101 added/, outcome.line)
  end

  def test_an_unchanged_sha_is_a_no_op
    options = sandbox
    Refresh.refresh_wpi(download: download(csv), **options)
    before = files(options)
    options[:table] = table.merge("IEORK" => ["Cork", 51.85, -8.2667, "wpi"], "ZZ001" => ["Port 1", 1.0, 1.0, "wpi"])

    # Same index saved with another line ending and a byte order mark, and a
    # newer snapshot date: not a new edition.
    outcome = Refresh.refresh_wpi(download: download("﻿#{csv.gsub("\n", "\r\n")}", snapshot: "2026-11-01"), **options)

    assert_equal "unchanged", outcome.status
    assert_equal before, files(options)
  end

  def test_a_rejected_download_leaves_all_three_files_alone
    options = sandbox
    Refresh.refresh_wpi(download: download(csv), **options)
    before = files(options)

    [csv(60), csv(100, cork: false), "<html>Maintenance</html>"].each do |bad|
      outcome = quiet { Refresh.refresh_wpi(download: download(bad), **options) }

      assert_equal "refused", outcome.status, outcome.line
      assert_equal before, files(options)
    end
  end

  def test_a_nothing_reachable_outcome_is_a_failure_not_a_refusal
    options = sandbox
    http = ->(*) { [503, "<html>".b, {}] }
    outcome = quiet { Refresh.refresh_wpi(http:, **options) }

    assert_equal "failed", outcome.status
    assert_match(/not refreshed, left as it was/, outcome.line)
    assert_equal [nil, nil, nil], files(options)
  end

  def test_refuses_a_regeneration_that_drops_more_than_two_percent_of_the_rows
    options = sandbox
    Refresh.refresh_wpi(download: download(csv), **options)
    before = files(options)
    options[:table] = table.merge((1..4).to_h { |n| ["ZZ#{format('%03d', n)}", ["Port #{n}", 1.0, 1.0, "unlocode"]] })

    outcome = Refresh.refresh_wpi(download: download(csv.sub("ZZ 050", "ZZ 150"), snapshot: "2026-11-01"), **options)

    assert_equal "refused", outcome.status
    assert_match(/rows would be removed/, outcome.line)
    assert_equal before, files(options)
  end

  def test_refuses_a_regeneration_that_moves_more_than_five_percent_over_a_kilometre
    options = sandbox
    Refresh.refresh_wpi(download: download(csv), **options)
    before = files(options)

    outcome = Refresh.refresh_wpi(download: download(csv(100, shift: 5), snapshot: "2026-11-01"), **options)

    assert_equal "refused", outcome.status
    assert_match(/moved over 1 km/, outcome.line)
    assert_equal before, files(options)
  end

  # Moving the three files is all or nothing: one that cannot be written puts
  # the others back.
  def test_a_failure_while_moving_files_into_place_restores_the_others
    options = sandbox
    Refresh.refresh_wpi(download: download(csv), **options)
    before = files(options)
    blocker = File.join(@dir, "blocker")
    File.write(blocker, "a file where a directory has to go")
    blocked = options.merge(coordinates_path: File.join(blocker, "coordinates_wpi.csv"))

    outcome = Refresh.refresh_wpi(download: download(csv.sub("Port 1,", "Port One,"), snapshot: "2026-11-01"), **blocked)

    assert_equal "failed", outcome.status
    assert_equal before.first(2), files(options).first(2), "the vendored copy and its provenance are put back"
  end

  def hits(count)
    (1..count).map { |n| Seaports::Wikidata::Hit.new(item: "Q#{n}", locode: "ZZ#{format('%03d', n)}", lat: n % 80, lng: n % 170, port: true) }
  end

  def wikidata_options
    @dir = Dir.mktmpdir
    { coordinates_path: File.join(@dir, "coordinates_wikidata.csv"), provenance_path: File.join(@dir, "wikidata_provenance.json"),
      table: table(100), held: [], today: Date.new(2026, 11, 21) }
  end

  # Enough codes to pass the floor without pretending to be 40,000 of them.
  def padded(hits)
    hits + (1..Seaports::Wikidata::EXPECTED_CODES).map { |n| Seaports::Wikidata::Hit.new(item: "P#{n}", locode: "QQ#{n}", lat: 1, lng: 1, port: false) }
  end

  def test_wikidata_refuses_an_answer_much_smaller_than_expected
    options = wikidata_options
    outcome = Refresh.refresh_wikidata(hits: hits(100), **options)

    assert_equal "refused", outcome.status
    assert_match(/fewer than/, outcome.line)
    refute File.exist?(options[:coordinates_path])
  end

  def test_wikidata_writes_the_file_and_its_retrieval_date_only_on_a_change
    options = wikidata_options
    first = Refresh.refresh_wikidata(hits: padded(hits(100)), **options)

    assert_equal "changed", first.status
    assert_equal "2026-11-21", JSON.parse(File.read(options[:provenance_path]))["retrieved_on"]
    assert_includes File.read(options[:coordinates_path]), "Wikidata Q1 (port, CC0)"

    again = Refresh.refresh_wikidata(hits: padded(hits(100)), **options.merge(today: Date.new(2026, 11, 28)))

    assert_equal "unchanged", again.status
    assert_equal "2026-11-21", JSON.parse(File.read(options[:provenance_path]))["retrieved_on"], "no change, no new date"
  end

  def test_wikidata_reports_the_codes_it_drops_for_not_being_port_typed
    options = wikidata_options
    towns = hits(100).map { |hit| hit.with(port: false) }
    outcome = Refresh.refresh_wikidata(hits: padded(towns), **options)

    assert_match(/100 not port typed on wikidata/, outcome.line)
  end

  def test_one_source_failing_does_not_stop_the_other
    wpi = Refresh.refresh_wpi(http: ->(*) { raise Errno::ECONNREFUSED }, **sandbox)
    wikidata = Refresh.refresh_wikidata(hits: padded(hits(100)), **wikidata_options)

    assert_equal %w[failed changed], [wpi.status, wikidata.status]
  end

  Diff = Struct.new(:ok, :changed) do
    def ok? = ok
    def changed? = changed
  end

  # The release is decided by the shipped table, not by the source files.
  def test_a_source_only_change_is_a_pull_request_without_a_release
    assert_equal "sources", Refresh.release_status(Diff.new(true, false), sources_changed: true)
    assert_equal "unchanged", Refresh.release_status(Diff.new(true, false), sources_changed: false)
    assert_equal "ok", Refresh.release_status(Diff.new(true, true), sources_changed: false)
    assert_equal "ok", Refresh.release_status(Diff.new(true, true), sources_changed: true)
    assert_equal "failed", Refresh.release_status(Diff.new(false, true), sources_changed: true)
  end

  def quiet(&)
    result = nil
    capture_io { result = yield }
    result
  end
end
