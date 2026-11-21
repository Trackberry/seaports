# frozen_string_literal: true

require "test_helper"
require "seaports/alternate_names"
require "seaports/builder"

class AlternateNamesTest < Minitest::Test
  Names = Seaports::AlternateNames

  def test_antwerpen_is_also_antwerp_and_anvers
    assert_equal "Antwerpen", Seaports.name("BEANR")
    assert_equal %w[Antwerp Anvers], Seaports.find("BEANR").alternate_names
    assert_equal %w[Antwerp Anvers], Seaports.alternate_names("beanr")
  end

  def test_a_port_with_no_other_name_or_an_unknown_code_has_none
    assert_equal [], Seaports.alternate_names("NLRTM")
    assert_equal [], Seaports.alternate_names("ZZZZZ")
    assert_equal [], Seaports.alternate_names(nil)
    assert_equal [], Seaports::Port.new(locode: "AAAAA", name: "A", coordinates: nil).alternate_names
  end

  def test_the_reviewed_file_adds_names_the_index_lacks
    assert_includes Seaports.alternate_names("ITGOA"), "Genoa"
    assert_includes Seaports.alternate_names("FRDKK"), "Dunkirk"
  end

  def test_a_parenthesized_english_name_is_an_alternate
    assert_includes Seaports.alternate_names("EGALY"), "Alexandria"
  end

  def test_no_alternate_equals_its_ports_own_name
    Seaports.all.each do |port|
      own = [port.name, port.name.sub(/\(.*\)/, "")].map { |name| Names.key(name) }
      port.alternate_names.each { |name| refute_includes own, Names.key(name), "#{port.locode} #{name}" }
      assert_equal port.alternate_names.map { |name| Names.key(name) }.uniq.size, port.alternate_names.size, port.locode
    end
  end

  def test_key_folds_case_accents_and_punctuation
    assert_equal "goteborg", Names.key("Göteborg")
    assert_equal "st petersburg", Names.key("St.-Petersburg")
    assert_equal "kobenhavn", Names.key("København")
  end

  def test_for_orders_layers_dedupes_and_drops_the_main_name
    layers = [{ "XXAAA" => ["Alpha", "Beta"] }, { "XXAAA" => ["beta", "Gamma", "Main"] }]
    assert_equal %w[Alpha Beta Gamma], Names.for(locode: "XXAAA", name: "Main", located: true, layers:)
    assert_equal %w[Alpha Beta Gamma Home], Names.for(locode: "XXAAA", name: "Main (Home)", located: true, layers:), "the parenthesis ranks last"
  end

  def test_for_reads_a_parenthesis_only_when_it_names_the_place
    assert_equal ["Alexandria"], Names.for(locode: "EGALY", name: "El Iskandariya (Alexandria)", located: true)
    assert_empty Names.for(locode: "EGALY", name: "El Iskandariya (Alexandria)", located: false)
    assert_empty Names.for(locode: "XXAAA", name: "Mumbai (ex Bombay)", located: true)
    assert_empty Names.for(locode: "XXAAA", name: "Place (Oil Terminal)", located: true)
  end

  def test_read_rejects_a_bad_row_with_its_line
    {
      "locode,name,source\nBEANR,,x\n" => /:2: BEANR has no name/,
      "locode,name,source\nBEANR,Antwerp,\n" => /:2: BEANR "Antwerp" has no source/,
      "locode,name,source\nBE,Antwerp,x\n" => /:2: "BE" is not a locode/,
      "locode,name,source\nBEANR,Antwerp,x\nBEANR,antwerp,x\n" => /:3: BEANR "antwerp" is listed twice/
    }.each do |text, message|
      path = File.join(Dir.mktmpdir, "names.csv")
      File.write(path, text)
      error = assert_raises(ArgumentError) { Names.read(path) }
      assert_match message, error.message
    end
  end

  def test_select_skips_unknown_ports_and_a_locode_on_several_rows
    candidates = [["BEANR", "Antwerp; Anvers"], ["XXNWR", "Nowhere"], ["ZZ001", "A"], ["ZZ001", "B"], ["SEGOT", " "]]
    rows, counts = Names.select(candidates, ports: Set["BEANR", "ZZ001", "SEGOT"], source: "wpi")

    assert_equal [%w[BEANR Antwerp wpi], %w[BEANR Anvers wpi]], rows
    assert_equal({ ports: 1, not_in_table: 1, duplicate: 1 }, counts)
  end

  def test_the_reviewed_file_is_valid_and_every_port_is_in_the_table
    names = Names.read(Seaports::Builder::ALTERNATE_NAMES_PATH)

    assert_operator names.size, :>=, 10
    names.each_key { |locode| refute_nil Seaports.find(locode), "#{locode} is not in the table" }
  end

  def test_most_ports_gain_names_from_the_world_port_index
    assert_operator Seaports.all.count { |port| port.alternate_names.any? }, :>, 500
  end
end
