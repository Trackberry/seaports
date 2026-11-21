# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

task default: [:test, :rubocop]

namespace :seaports do
  # Where a refresh leaves its evidence. The workflow reads these three files
  # rather than parsing this task's output, so a change to the wording here
  # cannot silently break the automation.
  REFRESH_DIR = "tmp/refresh"

  desc "Rebuild the table from a UN/LOCODE release and report what changed"
  task :refresh, [:source, :release, :subdivisions, :boundaries] do |_task, args|
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/diff"
    require_relative "lib/seaports/subdivisions"
    require_relative "lib/seaports/boundaries"
    require "fileutils"

    FileUtils.mkdir_p(REFRESH_DIR)
    before = File.join(REFRESH_DIR, "before.csv")
    FileUtils.cp(Seaports::TABLE_PATH, before)

    # Three downloads and a hand-edited overrides file: any of them failing is
    # a refusal for a person to read, the same as a failed gate, not a red
    # build nobody is told about.
    begin
      source = Seaports::Builder.fetch(args[:source] || Seaports::Builder::SOURCE_URL)
      subdivisions = Seaports::Subdivisions.parse(
        Seaports::Builder.fetch(args[:subdivisions] || Seaports::Subdivisions::SOURCE_URL)
      )
      boundaries = Seaports::Boundaries.parse(
        Seaports::Builder.fetch(args[:boundaries] || Seaports::Boundaries::SOURCE_URL)
      )
      builder = Seaports::Builder.new(source, subdivisions:, boundaries:, overrides: Seaports::Builder.overrides,
        coordinate_overrides: Seaports::Builder.coordinate_overrides,
        fallback_coordinates: Seaports::Builder.fallback_coordinates)
      builder.write(Seaports::TABLE_PATH)
    rescue StandardError => e
      FileUtils.cp(before, Seaports::TABLE_PATH)
      File.write(File.join(REFRESH_DIR, "summary.md"), "**Blocked**\n\nThe rebuild stopped: #{e.class}: #{e.message}\n")
      record "failed", "The rebuild stopped: #{e.class}: #{e.message}"
      next
    end

    diff = Seaports::Diff.between(before, Seaports::TABLE_PATH)
    overrides = builder.override_report
    summary = [diff.summary, overrides.empty? ? nil : "**Overrides to review**\n\n#{overrides.map { |line| "- #{line}" }.join("\n")}"]
    File.write(File.join(REFRESH_DIR, "summary.md"), "#{summary.compact.join("\n\n")}\n")
    puts overrides unless overrides.empty?

    if !diff.changed?
      record "unchanged", "The table is already current: #{diff.headline}"
    elsif !diff.ok?
      # Put the good table back. A refresh that fails its gates must leave no
      # trace in the working tree, so a later step cannot pick up half of it.
      FileUtils.cp(before, Seaports::TABLE_PATH)
      record "failed", "Refused the rebuilt table:\n#{diff.failures.map { |line| "  - #{line}" }.join("\n")}"
    else
      release = args[:release] || Seaports::Builder.published_release
      version = bump_version(release)
      write_changelog(version, release, diff)
      record "ok", "#{diff.headline}\nVersion #{version}, UN/LOCODE #{release || 'release unknown'}."
    end
  end

  # Recurring: run it after adding rows to data/sources/coordinate_overrides.csv
  # when a refresh is not due. Offline, and it only fills ports the table has
  # no position for; the next refresh rebuilds the same positions itself.
  desc "Write the reviewed coordinate overrides into the shipped table, without a download"
  task :apply_coordinates do
    require_relative "lib/seaports/builder"

    filled = Seaports::Builder.apply_coordinates
    puts "Filled #{filled.size} ports: #{filled.join(', ')}"
  end

  # Recurring: the weekly refresh runs it, and a person can run it by hand with
  # the path of a World Port Index CSV already downloaded (and its snapshot
  # date) when NGA and the Internet Archive are both out of reach.
  #
  # Looks for a newer World Port Index (NGA, else the Internet Archive),
  # validates it, replaces the vendored copy if its content differs, and
  # regenerates data/sources/coordinates_wpi.csv and the table from it. A
  # failure is reported and leaves every file as it was: the other sources
  # and the refresh carry on.
  desc "Fetch the newest NGA World Port Index and regenerate its coordinates"
  task :refresh_wpi, [:file, :snapshot] do |_task, args|
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/wpi"
    require "fileutils"
    FileUtils.mkdir_p(REFRESH_DIR)

    begin
      download =
        if args[:file]
          raise ArgumentError, "give the snapshot date too: refresh_wpi[file,YYYY-MM-DD]" if args[:snapshot].to_s.empty?

          Seaports::Wpi::Download.new(text: File.read(args[:file], encoding: "UTF-8"), url: File.basename(args[:file]),
            snapshot: args[:snapshot], via: "a local file")
        else
          Seaports::Wpi.fetch_latest
        end
      replaced = Seaports::Wpi.vendor(download) == :replaced
      snapshot = Seaports::Wpi.provenance.fetch("snapshot")
      candidates = Seaports::Wpi.candidates(File.read(Seaports::Wpi::CSV_PATH), source: Seaports::Wpi.source_label(snapshot))
      hand = Seaports::Builder.coordinate_overrides.keys
      line, changed = regenerate_coordinates("World Port Index (snapshot #{snapshot})", Seaports::Builder::WPI_COORDINATES_PATH,
        candidates, held: hand)
      changed ||= replaced
      line += " The vendored index was replaced (#{download.via}, #{download.url})." if replaced
      record_coordinates("wpi", changed ? "changed" : "unchanged", line)
    rescue StandardError => e
      record_coordinates("wpi", "failed", "World Port Index: not refreshed, left as it was (#{e.class}: #{e.message}).")
    end
  end

  # Recurring: the weekly refresh runs it. Wikidata is queried live, one
  # letter of the locode at a time, and the file is regenerated from the
  # answer. An answer much smaller than the file it replaces is refused.
  desc "Query Wikidata for positions and regenerate its coordinates"
  task :refresh_wikidata do
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/wikidata"
    require "fileutils"
    FileUtils.mkdir_p(REFRESH_DIR)

    begin
      path = Seaports::Builder::WIKIDATA_COORDINATES_PATH
      candidates, ambiguous = Seaports::Wikidata.candidates(Seaports::Wikidata.fetch_hits)
      raise "Wikidata answered with only #{candidates.size} codes" if candidates.size < 40_000 * Seaports::Wikidata::MINIMUM_SHARE
      held = Seaports::Builder.coordinate_overrides.keys + Seaports::Builder.coordinate_overrides(Seaports::Builder::WPI_COORDINATES_PATH).keys
      line, changed = regenerate_coordinates("Wikidata", path, candidates, held:, guard: Seaports::Wikidata::MINIMUM_SHARE,
        extra_counts: { ambiguous_on_wikidata: ambiguous })
      record_coordinates("wikidata", changed ? "changed" : "unchanged", line)
    rescue StandardError => e
      record_coordinates("wikidata", "failed", "Wikidata: not refreshed, left as it was (#{e.class}: #{e.message}).")
    end
  end

  # Runs after the two above. When the coordinates changed and the UN/LOCODE
  # refresh found nothing to release, they become the release: a version bump
  # and a changelog entry, and the status the workflow opens a pull request on.
  # When the refresh released something, the coordinate changes ride along in
  # its pull request and its summary.
  desc "Fold the coordinate refreshes into the refresh's summary, version and status"
  task :finish_coordinates do
    require_relative "lib/seaports/builder"
    require "date"

    notes = File.join(REFRESH_DIR, "coordinates.md")
    next unless File.exist?(notes)

    lines = File.readlines(notes, chomp: true)
    statuses = %w[wpi wikidata].map { |name| File.exist?(File.join(REFRESH_DIR, "#{name}_status")) ? File.read(File.join(REFRESH_DIR, "#{name}_status")).strip : nil }
    status_file = File.join(REFRESH_DIR, "status")
    status = File.exist?(status_file) ? File.read(status_file).strip : "unchanged"
    summary_file = File.join(REFRESH_DIR, "summary.md")
    summary = File.exist?(summary_file) ? File.read(summary_file).strip : ""
    block = "**Coordinates**\n\n#{lines.map { |line| "- #{line}" }.join("\n")}"
    File.write(summary_file, "#{[summary, block].reject(&:empty?).join("\n\n")}\n")

    if statuses.include?("changed")
      if status == "unchanged"
        version = bump_version(Seaports::DATA_RELEASE)
        content = File.read("CHANGELOG.md")
        entry = ["## #{version} — #{Date.today}", "", "Coordinates only, UN/LOCODE unchanged.", ""] + lines.map { |line| "- #{line}" }
        File.write("CHANGELOG.md", content.sub(/\n## /, "\n#{entry.join("\n")}\n\n## "))
        record "ok", "Coordinates changed: version #{version}."
      else
        puts "Coordinates changed: they ride along with the refresh."
      end
    else
      puts "No coordinate source changed."
    end
  end

  # Regenerates +path+ from +candidates+ and writes the result into the table.
  # Returns [one-line summary, whether the file changed]. +guard+ refuses a
  # result smaller than that share of the file it replaces.
  def regenerate_coordinates(label, path, candidates, held:, guard: nil, extra_counts: {})
    require_relative "lib/seaports/boundaries"
    require_relative "lib/seaports/coordinate_sources"

    previous = Seaports::Builder.all_coordinates
    before = Seaports::CoordinateSources.locodes(path)
    old_content = File.exist?(path) ? File.read(path) : nil
    result = Seaports::CoordinateSources.select(candidates, table: Seaports::CoordinateSources.table, held:, supplied: previous,
      boundaries: coordinate_boundaries)
    if guard && before.any? && result.rows.size < before.size * guard
      raise "only #{result.rows.size} ports to place, against #{before.size} in the file: not replaced"
    end

    Seaports::CoordinateSources.write(path, result.rows)
    Seaports::Builder.apply_coordinates(previous:)
    counts = result.counts.merge(extra_counts.reject { |_, n| n.zero? })
    line = Seaports::CoordinateSources.summary(label, before, result.rows.map(&:first), counts)
    puts line
    [line, File.read(path) != old_content]
  end

  # Natural Earth is 40 MB, and two steps of one refresh both want it.
  def coordinate_boundaries
    require_relative "lib/seaports/boundaries"
    cache = File.join(REFRESH_DIR, "boundaries.geojson")
    File.write(cache, Seaports::Builder.fetch(Seaports::Boundaries::SOURCE_URL)) unless File.exist?(cache)
    Seaports::Boundaries.parse(File.read(cache))
  end

  def record_coordinates(name, status, line)
    File.write(File.join(REFRESH_DIR, "#{name}_status"), "#{status}\n")
    File.write(File.join(REFRESH_DIR, "coordinates.md"), "#{line}\n", mode: "a")
    warn line if status == "failed"
  end

  def record(status, message)
    File.write(File.join(REFRESH_DIR, "status"), "#{status}\n")
    puts message
  end

  # A data refresh is a minor bump: ports appear and get renamed, which is
  # additive for anyone reading a name, and the code did not change.
  def bump_version(release)
    path = "lib/seaports/version.rb"
    major, minor, = Seaports::VERSION.split(".").map(&:to_i)
    version = "#{major}.#{minor + 1}.0"

    File.write(path, Seaports::Builder.stamp_version(File.read(path), version:, release:, refreshed_on: Date.today.iso8601))

    File.write(File.join(REFRESH_DIR, "version"), "#{version}\n")
    version
  end

  # The headline and the removals only. Everything else belongs in the pull
  # request, where it is read once; a changelog carrying four hundred added
  # ports is a changelog nobody opens twice.
  def write_changelog(version, release, diff)
    require "date"

    entry = ["## #{version} — #{Date.today}", "", "UN/LOCODE #{release || 'release unknown'}. #{diff.headline}"]
    unless diff.removed.empty?
      entry += ["", "Removed: #{diff.removed.join(', ')}."]
    end

    content = File.read("CHANGELOG.md")
    File.write("CHANGELOG.md", content.sub(/\n## /, "\n#{entry.join("\n")}\n\n## "))
  end
end
