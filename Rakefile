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
    require_relative "lib/seaports/coordinate_refresh"
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
      boundaries = coordinate_boundaries(args[:boundaries])
      builder = Seaports::Builder.new(source, subdivisions:, boundaries:, overrides: Seaports::Builder.overrides,
        coordinate_overrides: Seaports::Builder.coordinate_overrides,
        fallback_coordinates: Seaports::Builder.fallback_coordinates,
        alternate_names: Seaports::Builder.alternate_name_layers)
      builder.write(Seaports::TABLE_PATH)
    rescue StandardError => e
      FileUtils.cp(before, Seaports::TABLE_PATH)
      File.write(File.join(REFRESH_DIR, "summary.md"), "**Blocked**\n\nThe rebuild stopped: #{e.class}: #{e.message}\n")
      record "failed", "The rebuild stopped: #{e.class}: #{e.message}"
      next
    end

    diff = Seaports::Diff.between(before, Seaports::TABLE_PATH)
    overrides = builder.override_report
    coordinates = coordinate_notes
    summary = [diff.summary, overrides.empty? ? nil : "**Overrides to review**\n\n#{overrides.map { |line| "- #{line}" }.join("\n")}", coordinates]
    File.write(File.join(REFRESH_DIR, "summary.md"), "#{summary.compact.join("\n\n")}\n")
    puts overrides unless overrides.empty?

    status = Seaports::CoordinateRefresh.release_status(diff, sources_changed: coordinate_statuses.include?("changed"))
    case status
    when "unchanged"
      record "unchanged", "The table is already current: #{diff.headline}"
    when "failed"
      # Put the good table back. A refresh that fails its gates must leave no
      # trace in the working tree, so a later step cannot pick up half of it.
      FileUtils.cp(before, Seaports::TABLE_PATH)
      record "failed", "Refused the rebuilt table:\n#{diff.failures.map { |line| "  - #{line}" }.join("\n")}"
    when "sources"
      # The generated files moved and no port's position did, or not by 100 m:
      # worth a pull request to review, not a release.
      record "sources", "The coordinate sources changed and the table did not: no release.\n#{diff.headline}"
    else
      release = args[:release] || Seaports::Builder.published_release
      version = bump_version(release)
      write_changelog(version, release, diff)
      record "ok", "#{diff.headline}\nVersion #{version}, UN/LOCODE #{release || 'release unknown'}."
    end
  end

  # Recurring: run it after adding rows to data/sources/coordinate_overrides.csv
  # when a refresh is not due. Offline, and it never replaces a position
  # UN/LOCODE published (the table records which are); the next refresh
  # rebuilds the same positions itself.
  desc "Write the coordinate files into the shipped table, without a download"
  task :apply_coordinates do
    require_relative "lib/seaports/builder"

    changed = Seaports::Builder.apply_coordinates
    puts "Changed #{changed.size} ports: #{changed.first(40).join(', ')}#{changed.size > 40 ? ', ...' : ''}"
  end

  # Recurring: run it after adding rows to data/sources/alternate_names.csv when
  # a refresh is not due. Offline; the next refresh rebuilds the same names.
  desc "Write the alternate-name files into the shipped table, without a download"
  task :apply_alternate_names do
    require_relative "lib/seaports/builder"

    changed = Seaports::Builder.apply_alternate_names
    puts "Changed #{changed.size} ports: #{changed.first(40).join(', ')}#{changed.size > 40 ? ', ...' : ''}"
  end

  # Recurring: the weekly refresh runs it before seaports:refresh, and a person
  # can run it by hand with the path of a World Port Index CSV already
  # downloaded (and its snapshot date) when NGA and the Internet Archive are
  # both out of reach.
  #
  # Looks for a newer World Port Index (NGA, else the Internet Archive),
  # validates it, and moves the vendored copy, its provenance note,
  # data/sources/coordinates_wpi.csv and data/sources/alternate_names_wpi.csv
  # into place together, or none of them.
  # Does not touch the table: seaports:refresh merges the file next.
  desc "Fetch the newest NGA World Port Index and regenerate its coordinates"
  task :refresh_wpi, [:file, :snapshot] do |_task, args|
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/coordinate_refresh"
    require "fileutils"
    FileUtils.mkdir_p(REFRESH_DIR)

    download =
      if args[:file]
        raise ArgumentError, "give the snapshot date too: refresh_wpi[file,YYYY-MM-DD]" if args[:snapshot].to_s.empty?

        Seaports::Wpi::Download.new(text: File.read(args[:file], encoding: "UTF-8"), url: File.basename(args[:file]),
          snapshot: args[:snapshot], via: "a local file")
      end
    record_coordinates("wpi", Seaports::CoordinateRefresh.refresh_wpi(download:, boundaries: -> { coordinate_boundaries }))
  end

  # Recurring: the weekly refresh runs it, after refresh_wpi. Wikidata is
  # queried live, one letter of the locode at a time. The table is not
  # touched; seaports:refresh merges the file next.
  desc "Query Wikidata for positions and regenerate its coordinates"
  task :refresh_wikidata do
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/coordinate_refresh"
    require "fileutils"
    FileUtils.mkdir_p(REFRESH_DIR)

    record_coordinates("wikidata", Seaports::CoordinateRefresh.refresh_wikidata(boundaries: -> { coordinate_boundaries }))
  end

  # Natural Earth is 40 MB, and the two coordinate steps and the rebuild all
  # want it, so the first to need it downloads it and the rest read the copy.
  # An explicit +source+ (a path or URL) is read directly.
  def coordinate_boundaries(source = nil)
    require "fileutils"
    require_relative "lib/seaports/boundaries"
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/http"
    return Seaports::Boundaries.parse(Seaports::Builder.fetch(source)) if source

    FileUtils.mkdir_p(REFRESH_DIR)
    cache = File.join(REFRESH_DIR, "boundaries.geojson")
    unless File.exist?(cache)
      # Through Seaports::Http, for its User-Agent and its size cap.
      status, body, = Seaports::Http.get(Seaports::Boundaries::SOURCE_URL)
      raise "Natural Earth answered HTTP #{status}" unless status == 200

      File.binwrite(cache, body)
    end
    Seaports::Boundaries.parse(File.read(cache))
  end

  def record_coordinates(name, outcome)
    File.write(File.join(REFRESH_DIR, "#{name}_status"), "#{outcome.status}\n")
    File.write(File.join(REFRESH_DIR, "coordinates.md"), "#{outcome.line}\n", mode: "a")
    File.write(File.join(REFRESH_DIR, "coordinate_names.md"), "#{outcome.names}\n\n", mode: "a") unless outcome.names.empty?
    puts outcome.line
    warn outcome.line if %w[failed refused].include?(outcome.status)
  end

  def coordinate_statuses
    %w[wpi wikidata].filter_map do |name|
      path = File.join(REFRESH_DIR, "#{name}_status")
      File.read(path).strip if File.exist?(path)
    end
  end

  # The coordinate sources' part of the pull request body: what each did, what
  # was refused, and the names that differ. Also flags a refusal for the
  # workflow, which raises an issue for it.
  def coordinate_notes
    path = File.join(REFRESH_DIR, "coordinates.md")
    return nil unless File.exist?(path)

    File.write(File.join(REFRESH_DIR, "refused"), "yes\n") if coordinate_statuses.include?("refused")
    names = File.join(REFRESH_DIR, "coordinate_names.md")
    notes = File.readlines(path, chomp: true).map { |line| "- #{line}" }.join("\n")
    ["**Coordinate sources**\n\n#{notes}", File.exist?(names) ? File.read(names).strip : nil].compact.join("\n\n")
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
