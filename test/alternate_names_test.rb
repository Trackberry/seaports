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

  def test_no_alternate_is_another_ports_name_or_shared_in_its_country
    mains = Hash.new { |hash, key| hash[key] = [] }
    alternates = Hash.new { |hash, key| hash[key] = [] }
    Seaports.all.each do |port|
      [port.name, port.name.sub(/\(.*\)/, "")].each { |spelling| mains[[port.locode[0, 2], Names.key(spelling)]] << port.locode }
      port.alternate_names.each { |name| alternates[[port.locode[0, 2], Names.key(name)]] << port.locode }
    end

    alternates.each do |(country, name), locodes|
      assert_equal 1, locodes.size, "#{country} #{name.inspect} is an alternate of #{locodes.join(', ')}"
      assert_empty mains[[country, name]] - locodes, "#{country} #{name.inspect} is another port's own name"
    end
  end

  def test_the_collisions_in_the_review_are_gone
    assert_empty Seaports.alternate_names("CLANF")
    assert_empty Seaports.alternate_names("GBACV")
    assert_empty Seaports.alternate_names("JPOSA")
    %w[BEBRU BEMSJ BEODE].each { |locode| refute_includes Seaports.alternate_names(locode), "Bruxelles" }
  end

  def test_resolve_drops_another_ports_own_name_and_a_name_two_ports_share
    ports = [["AAONE", "One", %w[Shared Unique Two]], ["AATWO", "Two", %w[Shared Other]], ["AATHR", "Three", %w[Shared]],
             ["BBONE", "Elsewhere", %w[Shared Two]]]
    resolved = Names.resolve(ports)

    assert_equal %w[Unique], resolved["AAONE"], "Two is a port's name, Shared is on three ports"
    assert_equal %w[Other], resolved["AATWO"]
    assert_empty resolved["AATHR"]
    assert_equal %w[Shared Two], resolved["BBONE"], "another country does not collide"
  end

  def test_a_parenthesis_is_one_plain_name
    assert Names.parenthesis_name?("Alexandria")
    refute Names.parenthesis_name?("Ibiza/Eivissa"), "a list"
    refute Names.parenthesis_name?("Nuns, Island"), "a list"
    refute Names.parenthesis_name?("Ste"), "too short"
    ["ex Bombay", "Oil Terminal", "Tandem Load", "Ferry Port", "Port et Zone Franche", "Zone Franche", "Energy Terminal", "AFB", "Loop",
     "Fishing Ports", "Cargo Terminal"].each { |text| refute Names.parenthesis_name?(text), text }
  end

  def test_index_names_split_on_semicolons_and_commas_and_drop_junk
    countries = Set["mozambique"]

    assert_equal %w[Antwerp Anvers], Names.index_names("Antwerp; Anvers")
    assert_equal %w[Ghent Gand], Names.index_names("Ghent, Gand")
    ["FSO Kome", "FPSO Aoka", "FSPO Thing", "MV Baobab", "Shell Terminal", "Oil Berth", "Naval Port", "Kaupmees Sadamate", "Statoil AS",
     "Petroleum Quay", "Mozambique", "Bed", "Ab", "Base Nord", "Term. Sud"].each do |junk|
      assert_empty Names.index_names(junk, countries:), junk
    end
    assert_equal ["Assens"], Names.index_names("Assens", countries:), "AS only as a suffix"
    assert_equal ["Basel"], Names.index_names("Basel"), "Base only as a word"
  end

  def test_for_drops_a_rejected_name
    layers = [{ "XXAAA" => %w[Alpha Beta] }]

    assert_equal %w[Beta], Names.for(locode: "XXAAA", name: "Main", located: true, layers:, rejected: { "XXAAA" => ["alpha"] })
    assert_equal %w[Alpha Beta], Names.for(locode: "XXAAA", name: "Main", located: true, layers:, rejected: { "XXBBB" => ["alpha"] })
  end

  def test_the_rejected_file_is_valid_and_its_names_are_gone
    rejected = Seaports::Builder.rejected_alternate_names

    assert_equal 16, rejected.values.sum(&:size)
    rejected.each do |locode, names|
      names.each { |name| refute_includes Seaports.alternate_names(locode).map { |n| Names.key(n) }, Names.key(name), "#{locode} #{name}" }
    end
  end

  def test_read_requires_a_reason_in_the_rejected_file
    path = File.join(Dir.mktmpdir, "rejected.csv")
    File.write(path, "locode,name,reason\nBEANR,Antwerp,\n")

    error = assert_raises(ArgumentError) { Names.read(path, third: "reason") }
    assert_match(/has no reason/, error.message)
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
