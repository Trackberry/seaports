# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "seaports/release"
require "seaports/geometry/changes"

class ReleaseTest < Minitest::Test
  Release = Seaports::Release

  def test_next_version_bumps_minor_or_patch
    assert_equal "1.8.0", Release.next_version("1.7.6", :minor)
    assert_equal "1.7.7", Release.next_version("1.7.6", :patch)
    assert_raises(ArgumentError) { Release.next_version("1.7.6", :major) }
  end

  def test_stamp_lockfile_changes_both_of_the_gems_own_lines_and_nothing_else
    lockfile = File.read(Release::LOCKFILE_PATH)
    stamped = Release.stamp_lockfile(lockfile, "9.9.9")

    assert_equal 2, stamped.scan("seaports (9.9.9)").size
    assert_equal lockfile.lines.size, stamped.lines.size
    assert_equal lockfile.gsub("seaports (#{Seaports::VERSION})", "seaports (9.9.9)"), stamped
  end

  def test_prepend_changelog_puts_the_entry_above_the_newest
    content = "# Changelog\n\nIntro.\n\n## 1.0.0 — 2026-01-01\n\nOld.\n"

    assert_equal "# Changelog\n\nIntro.\n\n## 1.0.1 — 2026-02-01\n\nNew.\n\n## 1.0.0 — 2026-01-01\n\nOld.\n",
      Release.prepend_changelog(content, ["## 1.0.1 — 2026-02-01", "", "New."])
  end
end

class GeometryChangesTest < Minitest::Test
  Changes = Seaports::Geometry::Changes

  def feature(kind, osm, name: nil, x: 0)
    properties = { "kind" => kind, "osm" => Array(osm) }
    properties["name"] = name if name
    { "type" => "Feature", "properties" => properties,
      "geometry" => { "type" => "Polygon", "coordinates" => [[[x, 0], [x + 1, 0], [x + 1, 1], [x, 0]]] } }
  end

  def collection(*features) = { "type" => "FeatureCollection", "features" => features }

  def test_between_names_what_was_added_removed_and_changed_per_port
    before = {
      "NLRTM" => collection(feature("port_limits", %w[way/1 way/2]), feature("terminal", "way/1", name: "Euromax Terminal"),
        feature("anchorage", "relation/9", name: "4 East Anchorage")),
      "BEANR" => collection(feature("terminal", "way/5", name: "Deurganck")),
      "suez" => collection(feature("waterway", "way/7", name: "Suez Canal")).merge("name" => "Suez Canal")
    }
    after = {
      "NLRTM" => collection(feature("port_limits", %w[way/2 way/1], x: 1), feature("terminal", "way/1", name: "Euromax Terminal", x: 1),
        feature("anchorage", "way/10", name: "5 East Anchorage")),
      "BEANR" => collection(feature("terminal", "way/5", name: "Deurganck")),
      "suez" => collection(feature("waterway", "way/7", name: "Suez Canal", x: 2)).merge("name" => "Suez Canal")
    }

    ports = Changes.between(before, after, names: { "NLRTM" => "Rotterdam" })

    assert_equal %w[NLRTM suez], ports.map(&:id)
    assert_equal "Rotterdam (`NLRTM`): the port limits and Euromax Terminal changed; 5 East Anchorage added; 4 East Anchorage removed.",
      ports.first.line
    assert_equal "Suez Canal (`suez`): Suez Canal changed.", ports.last.line
  end

  def test_a_renamed_feature_is_changed_and_the_collections_own_fields_count
    before = { "NLRTM" => collection(feature("terminal", "way/1", name: "ECT Delta")).merge("quays" => ["NLBOT"], "selection_digest" => "a") }
    after = { "NLRTM" => collection(feature("terminal", "way/1", name: "Euromax Terminal")).merge("quays" => %w[NLBOT NLEUR], "selection_digest" => "b") }

    port = Changes.between(before, after, names: { "NLRTM" => "Rotterdam" }).first

    assert_equal ["Euromax Terminal"], port.changed
    assert_empty port.added
    assert_equal "Rotterdam (`NLRTM`): Euromax Terminal changed; the outline's quays and selection digest changed.", port.line

    only_fields = Changes.between({ "NLRTM" => collection.merge("quays" => []) }, { "NLRTM" => collection.merge("quays" => ["NLBOT"]) })
    assert_equal "NLRTM (`NLRTM`): the outline's quays changed.", only_fields.first.line
  end

  def test_a_port_new_on_one_side_is_all_added
    ports = Changes.between({ "NLRTM" => nil }, { "NLRTM" => collection(feature("terminal", "way/1", name: "Euromax Terminal")) })

    assert_equal ["Euromax Terminal"], ports.first.added
  end

  def test_perform_bumps_the_patch_version_and_logs_the_ports_that_moved
    Dir.mktmpdir do |root|
      old = collection(feature("terminal", "way/1", name: "Euromax Terminal"))
      write(root, "data/geometry/NLRTM.geojson", collection(feature("terminal", "way/1", name: "Euromax Terminal", x: 3)))
      write(root, "data/geometry/BEANR.geojson", collection(feature("terminal", "way/5", name: "Deurganck")))
      committed = { "data/geometry/NLRTM.geojson" => JSON.generate(old),
                    "data/geometry/BEANR.geojson" => File.read(File.join(root, "data/geometry/BEANR.geojson")) }
      release = release_files(root)

      ports = Changes.perform(read_before: committed.method(:[]), root:, out_dir: File.join(root, "out"), version: "1.7.6",
        date: Date.new(2026, 11, 30), release:)

      assert_equal %w[NLRTM], ports.map(&:id)
      assert_equal "ok\n", File.read(File.join(root, "out/status"))
      assert_equal "1.7.7\n", File.read(File.join(root, "out/version"))
      assert_includes File.read(release[:version_path]), 'VERSION = "1.7.7"'
      assert_includes File.read(release[:version_path]), 'DATA_REFRESHED_ON = "2026-11-21"', "an outline refresh leaves the table's date alone"
      assert_equal 2, File.read(release[:lockfile_path]).scan("seaports (1.7.7)").size
      changelog = File.read(release[:path])
      assert_match(/\A# Changelog\n\nIntro\.\n\n## 1\.7\.7 — 2026-11-30\n\n.*\n\n- Rotterdam \(`NLRTM`\): Euromax Terminal changed\.\n\n## 1\.7\.6/m, changelog)
      assert_includes File.read(File.join(root, "out/summary.md")), "Merging releases **1.7.7**"
    end
  end

  def test_perform_releases_nothing_when_no_outline_moved
    Dir.mktmpdir do |root|
      write(root, "data/geometry/BEANR.geojson", collection(feature("terminal", "way/5", name: "Deurganck")))
      committed = { "data/geometry/BEANR.geojson" => File.read(File.join(root, "data/geometry/BEANR.geojson")) }
      release = release_files(root)
      before = release.values.to_h { |path| [path, File.read(path)] }

      ports = Changes.perform(read_before: committed.method(:[]), root:, out_dir: File.join(root, "out"), version: "1.7.6", release:)

      assert_empty ports
      assert_equal "unchanged\n", File.read(File.join(root, "out/status"))
      refute File.exist?(File.join(root, "out/version"))
      before.each { |path, text| assert_equal text, File.read(path) }
    end
  end

  private

  def write(root, path, collection)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), JSON.generate(collection))
  end

  def release_files(root)
    files = { version_path: File.join(root, "version.rb"), lockfile_path: File.join(root, "Gemfile.lock"), path: File.join(root, "CHANGELOG.md") }
    File.write(files[:version_path], %(module Seaports\n  VERSION = "1.7.6"\n  DATA_REFRESHED_ON = "2026-11-21"\nend\n))
    File.write(files[:lockfile_path], "PATH\n  remote: .\n  specs:\n    seaports (1.7.6)\n\nCHECKSUMS\n  seaports (1.7.6)\n")
    File.write(files[:path], "# Changelog\n\nIntro.\n\n## 1.7.6 — 2026-11-23\n\nOld.\n")
    files
  end
end
