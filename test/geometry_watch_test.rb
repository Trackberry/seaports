# frozen_string_literal: true

require "test_helper"
require "rake"
require "seaports/geometry/watch"

class GeometryWatchTest < Minitest::Test
  Watch = Seaports::Geometry::Watch

  # Loads the Rakefile once per process: it defines constants and methods at
  # the top level, which a second load would redefine.
  def self.rake
    @rake ||= begin
      Rake.application = Rake::Application.new
      Rake.application.init("rake", [])
      load File.expand_path("../Rakefile", __dir__)
      Rake.application
    end
  end

  def element(type, id, tags, lat: 35.08, lon: 128.82)
    { "type" => type, "id" => id, "tags" => tags, "center" => { "lat" => lat, "lon" => lon },
      "bounds" => { "minlat" => lat - 0.005, "minlon" => lon - 0.005, "maxlat" => lat + 0.005, "maxlon" => lon + 0.005 } }
  end

  # Overpass's answer for each query, picked by the bounding box it asks
  # about: Busan New Port's (around KRBNP, 128.8 E) or Maputo's (32.5 E).
  def overpass(busan:, maputo:)
    lambda do |url, _headers|
      query = URI.decode_www_form_component(url.split("data=", 2).last)
      elements = query.include?(",128.") ? busan : maputo
      return [500, "busy", {}] if elements == :down

      [200, JSON.generate({ "elements" => elements }), {}]
    end
  end

  def busan_elements
    [
      element("way", 1, { "landuse" => "port", "name" => "Busan New Port" }),
      element("way", 3, { "industrial" => "container_terminal", "name" => "PNC", "operator" => "Pusan Newport Co." }),
      element("relation", 4, { "landuse" => "industrial", "name" => "HJNC 한진부산컨테이너터미널", "name:en" => "HJNC Container Terminal" }),
      element("node", 5, { "industrial" => "container_terminal", "name" => "A node is no outline" }),
      element("way", 6, { "industrial" => "container_terminal" }),
      element("way", 7, { "harbour" => "yes", "name" => "Busan Yacht Marina" }),
      # A terminal Rotterdam's shipped outline is built from: no news here.
      element("way", 597_875_321, { "industrial" => "container_terminal", "name" => "Euromax Terminal" })
    ]
  end

  def write_watch(dir, extra = "")
    path = File.join(dir, "watch.yml")
    File.write(path, <<~YAML + extra)
      ports:
        - locode: KRPUS
          name: Busan
          around: KRBNP
          radius_km: 12
          reason: OpenStreetMap maps none of Busan New Port's terminals.
          unblock: The New Port terminals mapped as areas.
          known:
            way/1: Busan New Port, the port area with no terminal in it
        - locode: MZMPM
          name: Maputo
          radius_km: 8
          reason: OpenStreetMap maps no terminal at Maputo.
          unblock: MPDC's container terminal mapped.
    YAML
    path
  end

  def issues
    [
      { "number" => 12, "state" => "OPEN", "body" => "<!-- port-watch: MZMPM -->\n[way/20](https://www.openstreetmap.org/way/20)",
        "comments" => [{ "body" => "More: way/21" }] },
      { "number" => 9, "state" => "CLOSED", "body" => "<!-- port-watch: KRPUS -->\nway/3 was the old PNC outline, no use.", "comments" => [] },
      { "number" => 3, "state" => "OPEN", "body" => "Not a port-watch issue: way/4", "comments" => [] }
    ]
  end

  def run_task(dir, http:)
    issues_path = File.join(dir, "issues.json")
    File.write(issues_path, JSON.generate(issues))
    task = self.class.rake["seaports:watch"]
    task.reenable
    out = StringIO.new
    Seaports::Http.stub(:get, http) do
      Watch.stub(:sleep, nil) do
        $stdout = out
        $stderr = StringIO.new
        task.invoke(issues_path, write_watch(dir), File.join(dir, "out"))
      ensure
        $stdout = STDOUT
        $stderr = STDERR
      end
    end
    out.string
  end

  def test_the_shipped_watch_list_is_valid_and_holds_no_outlined_port
    entries = Watch.load

    refute_empty entries
    entries.each do |entry|
      assert_nil Seaports.geometry(entry.locode), "#{entry.locode} is outlined: take it out of watch.yml"
    end
  end

  def test_load_refuses_typed_coordinates_and_missing_reasons
    Dir.mktmpdir do |dir|
      path = File.join(dir, "watch.yml")
      File.write(path, "ports:\n  - {locode: KRPUS, name: Busan, radius_km: 10, reason: x, unblock: y, lat: 35.1}\n")
      assert_match(/unknown keys lat/, assert_raises(Watch::Invalid) { Watch.load(path) }.message)

      File.write(path, "ports:\n  - {locode: KRPUS, name: Busan, radius_km: 10, unblock: y}\n")
      assert_match(/reason is missing/, assert_raises(Watch::Invalid) { Watch.load(path) }.message)

      File.write(path, "ports:\n  - {locode: KRPUS, name: Busan, radius_km: 100, reason: x, unblock: y}\n")
      assert_match(/radius_km/, assert_raises(Watch::Invalid) { Watch.load(path) }.message)

      File.write(path, "ports:\n  - {locode: ZZZZZ, name: Nowhere, radius_km: 5, reason: x, unblock: y}\n")
      assert_match(/not in the table/, assert_raises(Watch::Invalid) { Watch.load(path) }.message)

      File.write(path, "ports:\n  - {locode: KRPUS, name: Busan, radius_km: 5, reason: x, unblock: y, known: {way/x: no}}\n")
      assert_match(/not an OpenStreetMap reference/, assert_raises(Watch::Invalid) { Watch.load(path) }.message)
    end
  end

  def test_the_task_raises_only_named_areas_nobody_has_looked_at
    Dir.mktmpdir do |dir|
      maputo = [element("way", 20, { "landuse" => "port", "name" => "Porto de Maputo" }, lat: -25.97, lon: 32.55),
        element("way", 22, { "landuse" => "industrial", "name" => "Terminal de Contentores", "operator" => "MIPS" }, lat: -25.97, lon: 32.55)]
      log = run_task(dir, http: overpass(busan: busan_elements, maputo:))
      out = File.join(dir, "out")

      # Busan: way/1 is known, way/3 was in a closed issue, the node, the
      # unnamed way, the marina and Rotterdam's terminal are not candidates.
      busan = File.read(File.join(out, "KRPUS.md"))
      assert_includes busan, "<!-- port-watch: KRPUS -->"
      assert_includes busan, "[relation/4](https://www.openstreetmap.org/relation/4)"
      assert_includes busan, "`HJNC Container Terminal`"
      %w[way/1 way/3 node/5 way/6 way/7 way/597875321].each { |ref| refute_includes busan, "[#{ref}]" }
      assert_includes busan, "OpenStreetMap maps none of Busan New Port's terminals."
      assert_includes busan, "KRBNP's UN/LOCODE position"
      assert_equal "OpenStreetMap now maps terminals at Busan\n", File.read(File.join(out, "KRPUS.title"))
      refute File.exist?(File.join(out, "KRPUS.issue")), "no open issue for Busan, so a new one"

      # Maputo: way/20 was raised in the open issue, way/22 is new, and goes
      # to that issue as a comment.
      assert_equal "12\n", File.read(File.join(out, "MZMPM.issue"))
      maputo_comment = File.read(File.join(out, "MZMPM.md"))
      assert_includes maputo_comment, "[way/22]"
      refute_includes maputo_comment, "[way/20]"
      refute_includes maputo_comment, "<!-- port-watch", "a comment carries no marker"

      assert_includes log, "KRPUS: 3 candidate(s), 1 not looked at yet"
      assert_includes File.read(File.join(out, "summary.md")), "Maputo (`MZMPM`): 1 new: way/22"
    end
  end

  def test_the_task_writes_nothing_for_a_port_with_nothing_new
    Dir.mktmpdir do |dir|
      run_task(dir, http: overpass(busan: busan_elements.first(2), maputo: []))

      assert_equal %w[summary.md], Dir.children(File.join(dir, "out"))
    end
  end

  def test_the_task_fails_for_a_port_overpass_would_not_answer_after_writing_the_rest
    Dir.mktmpdir do |dir|
      error = assert_raises(SystemExit) { run_task(dir, http: overpass(busan: busan_elements, maputo: :down)) }

      refute error.success?
      assert File.exist?(File.join(dir, "out", "KRPUS.md"))
      assert_includes File.read(File.join(dir, "out", "summary.md")), "Maputo (`MZMPM`): not checked: Overpass refused the query"
    end
  end

  def test_a_port_now_outlined_is_skipped_and_named
    Dir.mktmpdir do |dir|
      path = File.join(dir, "watch.yml")
      File.write(path, "ports:\n  - {locode: NLRTM, name: Rotterdam, radius_km: 5, reason: x, unblock: y}\n")
      out = StringIO.new
      results = Watch.perform(path:, out_dir: File.join(dir, "out"), http: ->(*) { flunk "no query for an outlined port" }, out:)

      assert_empty results
      assert_includes out.string, "NLRTM: now outlined"
    end
  end

  def test_names_from_openstreetmap_cannot_break_the_table_or_mention_anyone
    assert_equal "`a \\| b @someone`", Watch.code("a | b `@someone`")
  end
end
