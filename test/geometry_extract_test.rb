# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"
require "seaports/geometry/extract"

class GeometryExtractTest < Minitest::Test
  Extract = Seaports::Geometry::Extract
  Osm = Seaports::Geometry::Osm
  Status = Struct.new(:success?)

  # A Geofabrik index in miniature: a continent cut into a west and an east
  # country with open sea beyond them (x 10 to 12), and a county inside the
  # west one.
  def index
    square = ->(id, parent, x1, y1, x2, y2) do
      { "type" => "Feature",
        "properties" => { "id" => id, "parent" => parent, "urls" => { "pbf" => "https://download.geofabrik.de/#{id}/#{id.split('/').last}-latest.osm.pbf" } },
        "geometry" => { "type" => "MultiPolygon", "coordinates" => [[[[x1, y1], [x2, y1], [x2, y2], [x1, y2], [x1, y1]]]] } }
    end
    JSON.generate({ "type" => "FeatureCollection", "features" => [
      square.("continent", nil, 0, 0, 12, 10),
      square.("continent/west", "continent", 0, 0, 5, 10),
      square.("continent/east", "continent", 5, 0, 10, 10),
      square.("continent/west/county", "continent/west", 1, 1, 2, 2),
      { "type" => "Feature", "properties" => { "id" => "no-extract" }, "geometry" => nil }
    ] })
  end

  def regions = Extract.regions(index)
  def path_of(points) = Extract.smallest(regions, points).path

  def test_reads_the_regions_that_have_an_extract
    assert_equal ["continent", "continent/east", "continent/west", "continent/west/county"], regions.map(&:path).sort
  end

  def test_the_smallest_region_that_holds_every_point
    assert_equal "continent/west/county", path_of([[1.5, 1.5]])
    assert_equal "continent/west", path_of([[1.5, 1.5], [3, 3]])
  end

  # Across two countries, only their parent holds the shape.
  def test_falls_back_to_the_parent_across_a_border
    assert_equal "continent", path_of([[4, 4], [6, 4]])
  end

  def test_refuses_a_point_no_region_holds
    assert_raises(Osm::Error) { path_of([[20, 20]]) }
  end

  def covers(points) = Extract.covers(regions, points).map { |cover| cover.map(&:path) }

  # Two countries rather than the continent: each is a smaller download.
  def test_covers_a_shape_across_a_border_with_one_region_each_side
    assert_equal [["continent/east", "continent/west"]], covers([[4, 4], [6, 4]])
  end

  # A shape reaching out of the county is tried in the county's extract,
  # which carries a way that enters it whole, and then in the country's.
  def test_tries_the_county_a_shape_enters_before_the_country_that_holds_it
    assert_equal [["continent/west/county"], ["continent/west"]], covers([[1.5, 1.5], [3, 3]])
  end

  # Out at sea only the continent holds the shape's far end.
  def test_never_chooses_a_continent
    assert_equal [["continent/east"]], covers([[9, 5], [11, 5]])
    error = assert_raises(Osm::Error) { covers([[11, 5]]) }
    assert_match "OSM_REGION", error.message
  end

  def test_ignores_a_point_no_region_holds
    assert_equal [["continent/west/county"]], covers([[1.5, 1.5], [30, 30]])
    assert_raises(Osm::Error) { covers([[30, 30]]) }
  end

  def test_a_sample_is_spread_and_keeps_both_ends
    sample = Extract.sample((1..100).to_a, 5)

    assert_equal [1, 25, 50, 75, 100], sample
  end

  def test_a_cached_file_is_fresh_until_it_is_max_age_days_old
    Dir.mktmpdir do |dir|
      path = File.join(dir, "region.osm.pbf")
      refute Extract.fresh?(path, max_age_days: 3)

      File.write(path, "pbf")
      written = Time.utc(2026, 11, 20, 12)
      File.utime(written, written, path)

      assert Extract.fresh?(path, max_age_days: 3, now: written + (2 * 86_400))
      refute Extract.fresh?(path, max_age_days: 3, now: written + (3 * 86_400))
    end
  end

  # osmium's OPL for the same features as OVERPASS below: a node, a closed
  # way, an open way and a multipolygon relation with a hole, whose outer
  # ring is drawn in two ways, one of them backwards.
  OPL = <<~OPL
    n1 T x0 y0
    n2 T x4 y0
    n3 T x4 y4
    n4 T x0 y4
    n5 T x1 y1
    n6 T x2 y1
    n7 T x2 y2
    n8 T x1 y2
    n9 Tseamark:type=pilot_boarding x3.1234567 y51.7654321
    w10 Tlanduse=port Nn1,n2,n3,n4,n1
    w11 Tman_made=pier Nn5,n6,n7
    w12 T Nn1,n2,n3
    w13 T Nn1,n4,n3
    w14 T Nn5,n8,n7,n6,n5
    r20 Ttype=multipolygon Mw12@outer,w13@outer,w14@inner,n9@label
  OPL

  def overpass_node(lon, lat) = { "lon" => lon, "lat" => lat }

  # What Overpass's "out geom" answers for the same features.
  def overpass_elements
    square = [overpass_node(0, 0), overpass_node(4, 0), overpass_node(4, 4), overpass_node(0, 4), overpass_node(0, 0)]
    [
      { "type" => "node", "id" => 9, "lat" => 51.7654321, "lon" => 3.1234567 },
      { "type" => "way", "id" => 10, "geometry" => square },
      { "type" => "way", "id" => 11, "geometry" => [overpass_node(1, 1), overpass_node(2, 1), overpass_node(2, 2)] },
      { "type" => "relation", "id" => 20, "members" => [
        { "type" => "way", "ref" => 12, "role" => "outer", "geometry" => [overpass_node(0, 0), overpass_node(4, 0), overpass_node(4, 4)] },
        { "type" => "way", "ref" => 13, "role" => "outer", "geometry" => [overpass_node(0, 0), overpass_node(0, 4), overpass_node(4, 4)] },
        { "type" => "way", "ref" => 14, "role" => "inner",
          "geometry" => [overpass_node(1, 1), overpass_node(1, 2), overpass_node(2, 2), overpass_node(2, 1), overpass_node(1, 1)] },
        { "type" => "node", "ref" => 9, "role" => "label", "lat" => 51.7654321, "lon" => 3.1234567 }
      ] }
    ]
  end

  REFS = ["node/9", "way/10", "way/11", "relation/20"].freeze

  def teardown
    (@dirs || []).each { |dir| FileUtils.rm_rf(dir) }
  end

  # An Extract over a cache holding the miniature index and fresh,
  # already-downloaded extracts of the county and the west country, with
  # osmium answering +opl+, or +opl+.call(pbf) when it is a lambda.
  def extract(opl: OPL, stderr: "", ok: true, calls: [], region: nil)
    dir = Dir.mktmpdir
    (@dirs ||= []) << dir
    File.write(File.join(dir, "index-v1.json"), index)
    ["continent/west/county/county", "continent/west/west"].each do |name|
      pbf = File.join(dir, "#{name}-latest.osm.pbf")
      FileUtils.mkdir_p(File.dirname(pbf))
      File.write(pbf, "pbf")
    end
    osmium = lambda do |*args|
      calls << args
      next ["2026-11-22T21:21:42Z\n", "", Status.new(true)] if args[1] == "fileinfo"

      [opl.respond_to?(:call) ? opl.call(args.find { |arg| arg.end_with?(".pbf") }) : opl, stderr, Status.new(ok)]
    end
    Extract.new(cache_dir: dir, osmium:, region:, out: StringIO.new, http: ->(*) { flunk "no network" },
      download: ->(*) { flunk "no download" })
  end

  def test_turns_osmium_objects_into_overpass_elements
    objects = Extract.objects(OPL)
    elements = REFS.map { |ref| Extract.element(ref, objects) }

    assert_equal({ "type" => "Point", "coordinates" => [3.123457, 51.765432] }, Osm.shape(elements[0]))
    assert_equal "Polygon", Osm.shape(elements[1])["type"]
    assert_equal({ "type" => "LineString", "coordinates" => [[1.0, 1.0], [2.0, 1.0], [2.0, 2.0]] }, Osm.shape(elements[2]))
    relation = Osm.shape(elements[3])
    assert_equal "Polygon", relation["type"]
    assert_equal 2, relation["coordinates"].size, "the inner ring is a hole in the outer"
    assert_equal({ "type" => "node", "ref" => 9, "role" => "label", "lat" => 51.7654321, "lon" => 3.1234567 }, elements[3]["members"].last)
  end

  # The point of the whole module: the same OpenStreetMap data gives the
  # same shapes, coordinate for coordinate, from either source.
  def test_gives_exactly_what_overpass_gives_for_the_same_data
    body = JSON.generate({ "elements" => overpass_elements })
    from_overpass = Osm.shapes(REFS, http: ->(*) { [200, body] })
    from_extract = extract.shapes(REFS, position: [1.5, 1.5])

    assert_equal JSON.generate(from_overpass), JSON.generate(from_extract)
  end

  def test_asks_osmium_for_the_features_and_what_they_reference
    calls = []
    extract(calls:).shapes(["way/10", "relation/20"], position: [1.5, 1.5])
    getid = calls.find { |args| args[1] == "getid" }

    assert_includes getid, "--add-referenced"
    assert_includes getid, "--verbose-ids", "without it osmium says nothing when an id is missing, which a region across a border always has"
    assert_equal ["w10", "r20"], getid.last(2)
    assert getid.any? { |arg| arg.end_with?("continent/west/county/county-latest.osm.pbf") }
  end

  def test_a_missing_feature_raises
    error = assert_raises(Osm::Error) do
      extract(stderr: "[ 0:00] Did not find 1 object(s).\nMissing way IDs: 99\n", ok: false).shapes(["way/10", "way/99"], position: [1.5, 1.5])
    end
    assert_match "OpenStreetMap has no way/99 in Geofabrik's continent/west/county", error.message
    assert_match "OSM_REGION", error.message
  end

  # way/10 is not in the county's extract at all, and is found in the west
  # country's; way/11, only ever looked for in the county, is not asked for
  # again.
  def test_looks_for_a_missing_feature_in_the_next_regions
    shape = ->(points) { { "type" => "Polygon", "coordinates" => [points] } }
    outline = { "features" => [
      { "properties" => { "osm" => ["way/10"], "source" => "OpenStreetMap way 10" }, "geometry" => shape.([[1.5, 1.5], [3, 3], [1.5, 3], [1.5, 1.5]]) },
      { "properties" => { "osm" => ["way/11"], "source" => "OpenStreetMap way 11" }, "geometry" => shape.([[1.2, 1.2], [1.8, 1.2], [1.8, 1.8], [1.2, 1.2]]) }
    ] }
    calls = []
    opl = ->(pbf) { pbf.include?("county") ? OPL.lines.reject { |line| line.start_with?("w10 ") }.join : OPL }

    shapes = extract(opl:, calls:).shapes(["way/10", "way/11"], outline:)

    assert_equal ["way/10", "way/11"], shapes.keys
    getids = calls.select { |args| args[1] == "getid" }.map do |args|
      pbf = args.index { |arg| arg.end_with?(".pbf") }
      [args[pbf].split("/").last, args[(pbf + 1)..]]
    end
    assert_equal [["county-latest.osm.pbf", ["w10", "w11"]], ["west-latest.osm.pbf", ["w10"]]], getids
  end

  def test_an_osmium_failure_is_not_taken_for_a_missing_feature
    error = assert_raises(Osm::Error) do
      extract(opl: "", stderr: "Error: PBF error: invalid BlobHeader size", ok: false).shapes(["way/10"], position: [1.5, 1.5])
    end
    assert_match "osmium getid failed", error.message
  end

  # A way whose nodes run past the extract's edge would otherwise come back
  # shorter than it is.
  def test_a_way_with_a_node_outside_the_extract_raises
    opl = OPL.lines.reject { |line| line.start_with?("n3 ") }.join

    error = assert_raises(Osm::Error) { extract(opl:).shapes(["way/10"], position: [1.5, 1.5]) }
    assert_match "node/3", error.message
  end

  def test_a_relation_with_a_member_outside_the_extract_raises
    opl = OPL.lines.reject { |line| line.start_with?("w13 ") }.join

    error = assert_raises(Osm::Error) { extract(opl:).shapes(["relation/20"], position: [1.5, 1.5]) }
    assert_match "way/13", error.message
  end

  def test_an_opl_role_is_unescaped
    objects = Extract.objects("r1 T Mw2@main%20%stream,n3@\n")

    assert_equal ["main stream", ""], objects["relation/1"]["members"].map { |m| m["role"] }
  end

  # A shipped feature is read from the region its shape lies in, not from
  # around the port's position.
  def test_a_shipped_feature_chooses_its_region_by_its_shape
    outline = { "features" => [{ "properties" => { "osm" => ["way/10"], "source" => "OpenStreetMap way 10" },
      "geometry" => { "type" => "Polygon", "coordinates" => [[[6, 6], [7, 6], [7, 7], [6, 6]]] } }] }

    paths = ->(ref) { extract.regions_for(ref, outline, [1.5, 1.5]).map { |cover| cover.map(&:path) } }

    assert_equal [["continent/east"]], paths.("way/10")
    assert_equal [["continent/east", "continent/west/county"]], paths.("way/11"), "a new feature is looked for where the whole port is"
  end

  # Derived port limits are a hull out to sea, and choose nothing.
  def test_derived_port_limits_do_not_choose_a_region
    outline = { "features" => [{ "properties" => { "osm" => ["way/10"], "source" => "Derived: the convex hull" },
      "geometry" => { "type" => "Polygon", "coordinates" => [[[6, 6], [7, 6], [7, 7], [6, 6]]] } }] }

    assert_equal [["continent/west/county"]], extract.regions_for("way/10", outline, [1.5, 1.5]).map { |cover| cover.map(&:path) }
  end

  # The county's extract lacks a node of the way, which reaches out of it;
  # the west country's has it, so the way is read from there.
  def test_reads_a_shape_from_the_next_regions_when_the_first_leave_part_of_it_out
    outline = { "features" => [{ "properties" => { "osm" => ["way/10"], "source" => "OpenStreetMap way 10" },
      "geometry" => { "type" => "Polygon", "coordinates" => [[[1.5, 1.5], [3, 3], [1.5, 3], [1.5, 1.5]]] } }] }
    calls = []
    opl = ->(pbf) { pbf.include?("county") ? OPL.lines.reject { |line| line.start_with?("n3 ") }.join : OPL }

    shape = extract(opl:, calls:).shapes(["way/10"], outline:)["way/10"]

    assert_equal "Polygon", shape["type"]
    assert_equal 5, shape["coordinates"].first.size
    read = calls.select { |args| args[1] == "getid" }.map { |args| args.find { |arg| arg.end_with?(".pbf") }.split("/").last }
    assert_equal ["county-latest.osm.pbf", "west-latest.osm.pbf"], read
  end

  def test_a_shape_no_region_holds_whole_raises
    outline = { "features" => [{ "properties" => { "osm" => ["way/10"], "source" => "OpenStreetMap way 10" },
      "geometry" => { "type" => "Polygon", "coordinates" => [[[1.5, 1.5], [3, 3], [1.5, 3], [1.5, 1.5]]] } }] }
    opl = OPL.lines.reject { |line| line.start_with?("n3 ") }.join

    error = assert_raises(Extract::Incomplete) { extract(opl:).shapes(["way/10"], outline:) }
    assert_match "continent/west", error.message
  end

  def test_downloads_a_stale_extract_and_checks_its_md5
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "index-v1.json"), index)
      dated = "https://download.geofabrik.de/continent/west/county/county-261122.osm.pbf"
      download = lambda do |url, path|
        assert_equal "https://download.geofabrik.de/continent/west/county/county-latest.osm.pbf", url
        File.write(path, "fresh pbf")
        dated
      end
      md5 = Digest::MD5.hexdigest("fresh pbf")
      http = ->(url, _headers) { url == "#{dated}.md5" ? [200, "#{md5}  county-261122.osm.pbf\n"] : [404, ""] }
      osmium = ->(*args) { args[1] == "fileinfo" ? ["", "", Status.new(true)] : [OPL, "", Status.new(true)] }
      source = Extract.new(cache_dir: dir, osmium:, out: StringIO.new, http:, download:)

      source.shapes(["way/10"], position: [1.5, 1.5])

      assert_equal "fresh pbf", File.read(File.join(dir, "continent/west/county/county-latest.osm.pbf"))
    end
  end

  def test_refuses_a_download_that_does_not_match_its_md5
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "index-v1.json"), index)
      download = ->(url, path) { File.write(path, "cut sho") && url }
      http = ->(_url, _headers) { [200, "#{Digest::MD5.hexdigest('cut short')}  county-latest.osm.pbf\n"] }
      source = Extract.new(cache_dir: dir, osmium: ->(*) { flunk "never read" }, out: StringIO.new, http:, download:)

      assert_raises(Osm::Error) { source.shapes(["way/10"], position: [1.5, 1.5]) }
      assert_empty Dir[File.join(dir, "continent/west/county/*")], "neither the bad download nor its part file is kept"
    end
  end

  def test_names_one_region_for_every_feature
    source = extract(region: "continent/west/county")

    assert_equal [["continent/west/county"]], source.regions_for("way/10", nil, nil).map { |cover| cover.map(&:path) }
  end

  # The names the name rule reads come from the objects the shapes were
  # read from, with no second pass over the extract.
  def test_the_names_come_from_the_same_read_as_the_shapes
    named = OPL.sub("w10 Tlanduse=port ", "w10 Tlanduse=port,name=Port%20%Nord,name:en=North%20%Port,operator=X ")
    calls = []
    source = extract(opl: named, calls:)
    source.shapes(["way/10", "node/9"], position: [1.5, 1.5])
    reads = calls.size

    assert_equal({ "way/10" => { "name" => "Port Nord", "name:en" => "North Port" }, "node/9" => {} },
      source.tags_for("NLRTM").call(["way/10", "node/9"]))
    assert_equal reads, calls.size
  end

  # The scan keeps nodes, unlike the water: a place is a node.
  def test_the_inside_scan_cuts_the_box_and_filters_by_the_scans_tags
    opl = "n1 Tplace=hamlet,name=Les%20%Neiges x1.5 y1.5\nn2 T x1.6 y1.5\n"
    calls = []
    elements = extract(opl:, calls:).inside([1.2, 1.2, 1.8, 1.8], label: "NLRTM")
    filter = calls.find { |args| args[1] == "tags-filter" }

    assert_equal [{ "type" => "node", "id" => 1, "lat" => 1.5, "lon" => 1.5, "tags" => { "place" => "hamlet", "name" => "Les Neiges" } }], elements
    assert_equal Seaports::Geometry::Inside::FILTERS, filter.last(Seaports::Geometry::Inside::FILTERS.size)
    assert(calls.any? { |args| args[1] == "extract" && args.include?("1.2,1.2,1.8,1.8") })
  end
end
