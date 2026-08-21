# frozen_string_literal: true

require "test_helper"

class DiffTest < Minitest::Test
  # A table that passes every gate, so each test can break exactly one thing
  # and know that is what it is reading.
  def healthy(extra = {})
    ports = Seaports::Diff::ANCHORS.each_with_object({}) do |locode, table|
      table[locode] = { name: locode, point: [1.0, 2.0] }
    end
    filler = (Seaports::Diff::MINIMUM_COUNT + 100 - ports.size - extra.size)
    filler.times { |index| ports["ZZ#{index.to_s.rjust(3, '0')}"] = { name: "Filler #{index}", point: nil } }
    ports.merge(extra)
  end

  def test_a_table_that_did_not_move_reports_no_change
    diff = Seaports::Diff.new(healthy, healthy)

    refute_predicate diff, :changed?
    assert_predicate diff, :ok?
  end

  def test_names_what_a_release_added_and_took_away
    diff = Seaports::Diff.new(healthy("AAAAA" => port("Gone")), healthy("BBBBB" => port("New")))

    assert_equal ["BBBBB"], diff.added
    assert_equal ["AAAAA"], diff.removed
    assert_predicate diff, :changed?
  end

  def test_names_a_port_that_kept_its_code_and_changed_its_name
    diff = Seaports::Diff.new(healthy("AAAAA" => port("Bombay")), healthy("AAAAA" => port("Mumbai")))

    assert_equal [["AAAAA", "Bombay", "Mumbai"]], diff.renamed
    assert_empty diff.added
    assert_empty diff.removed
  end

  # The three position changes read differently downstream: a marker appears,
  # a marker vanishes, a marker slides. A refresh should say which.
  def test_distinguishes_the_three_kinds_of_position_change
    before = healthy("AAAAA" => port("Gains", nil), "BBBBB" => port("Loses", [1.0, 1.0]), "CCCCC" => port("Moves", [1.0, 1.0]))
    after = healthy("AAAAA" => port("Gains", [2.0, 2.0]), "BBBBB" => port("Loses", nil), "CCCCC" => port("Moves", [9.0, 9.0]))

    assert_equal %i[located unlocated moved], Seaports::Diff.new(before, after).repositioned.map(&:last)
  end

  def test_refuses_a_table_that_lost_too_many_ports_at_once
    after = healthy.first(Seaports::Diff::MINIMUM_COUNT + 100 - 400).to_h
    diff = Seaports::Diff.new(healthy, after)

    refute_predicate diff, :ok?
    assert_match(/shrank by/, diff.failures.join)
  end

  def test_refuses_a_table_that_is_simply_too_small
    diff = Seaports::Diff.new(healthy, healthy.first(50).to_h)

    refute_predicate diff, :ok?
    assert_match(/below the floor/, diff.failures.join)
  end

  # The gate that catches a source which truncated one region rather than the
  # whole file, which a row count alone would sail straight past.
  def test_refuses_a_table_that_lost_a_port_too_large_to_lose
    after = healthy
    after.delete("SGSIN")
    after["ZZZZZ"] = port("Replacement")

    diff = Seaports::Diff.new(healthy, after)

    refute_predicate diff, :ok?
    assert_match(/SGSIN/, diff.failures.join)
  end

  def test_refuses_a_table_that_quietly_reclassified_the_panama_canal
    diff = Seaports::Diff.new(healthy, healthy("PAPCN" => port("Panama Canal")))

    refute_predicate diff, :ok?
    assert_match(/deliberately/, diff.failures.join)
  end

  def test_an_ordinary_release_passes
    after = healthy("AAAAA" => port("New Port"))
    after.delete("ZZ001")

    assert_predicate Seaports::Diff.new(healthy, after), :ok?
  end

  # Removals are the changes that break a caller, so they are never elided,
  # however many of them there are.
  def test_lists_every_removal_but_caps_the_additions
    before = healthy((1..60).to_h { |index| ["R#{index.to_s.rjust(4, '0')}", port("Removed #{index}")] })
    after = healthy((1..60).to_h { |index| ["A#{index.to_s.rjust(4, '0')}", port("Added #{index}")] })
    summary = Seaports::Diff.new(before, after).summary

    assert_equal 60, summary.scan(/`R\d{4}`/).size
    assert_match(/…and 20 more/, summary)
  end

  def test_a_blocked_refresh_says_so_at_the_top_of_its_summary
    summary = Seaports::Diff.new(healthy, healthy.first(50).to_h).summary

    assert_match(/\*\*Blocked\*\*/, summary)
  end

  def test_reads_two_csv_files_off_disk
    dir = Dir.mktmpdir
    before = File.join(dir, "before.csv")
    after = File.join(dir, "after.csv")
    File.write(before, "locode,name,lat,lng\nAUBNE,Brisbane,-27.4667,153.0167\nGBFXT,Felixstowe,,\n")
    File.write(after, "locode,name,lat,lng\nAUBNE,Brisbane Pt,-27.4667,153.0167\nSGSIN,Singapore,1.28,103.85\n")

    diff = Seaports::Diff.between(before, after)

    assert_equal ["SGSIN"], diff.added
    assert_equal ["GBFXT"], diff.removed
    assert_equal [["AUBNE", "Brisbane", "Brisbane Pt"]], diff.renamed
  end

  # The shipped table has to survive its own gates, or the first refresh will
  # be judged against a baseline that was never good.
  def test_the_shipped_table_passes_its_own_gates
    diff = Seaports::Diff.between(Seaports::TABLE_PATH, Seaports::TABLE_PATH)

    assert_predicate diff, :ok?
    refute_predicate diff, :changed?
  end

  private

  def port(name, point = [1.0, 2.0])
    { name: name, point: point }
  end
end
