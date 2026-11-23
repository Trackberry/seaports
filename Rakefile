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

task default: [:test, "seaports:check_geometry", :rubocop]

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
        alternate_names: Seaports::Builder.alternate_name_layers, rejected_names: Seaports::Builder.rejected_alternate_names)
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

    entry = ["## #{version} — #{Date.today}", "", "UN/LOCODE #{release || 'release unknown'}. #{[diff.headline, diff.names_headline].compact.join(' ')}"]
    unless diff.removed.empty?
      entry += ["", "Removed: #{diff.removed.join(', ')}."]
    end

    content = File.read("CHANGELOG.md")
    File.write("CHANGELOG.md", content.sub(/\n## /, "\n#{entry.join("\n")}\n\n## "))
  end
end

namespace :seaports do
  # Recurring: the draft of a port's selection starts here. Writes every
  # OpenStreetMap feature near the port that could be part of it to
  # tmp/geometry/<LOCODE>.candidates.json, ids and tags but no shapes, for a
  # person or an agent to choose from in data/geometry/sources/<LOCODE>.yml.
  desc "List the OpenStreetMap features near a port, to choose its outline from"
  #
  # With +lat+ and +lng+ it searches around that position instead, and adds
  # what it finds to the port's file: for anchorages far out, like
  # Antwerp's off Vlissingen.
  task :geometry_candidates, [:locode, :radius_km, :lat, :lng] do |_task, args|
    require "fileutils"
    require "json"
    require_relative "lib/seaports/geometry/candidates"

    locode = args.fetch(:locode).upcase
    radius_km = (args[:radius_km] || 20).to_f
    candidates =
      if args[:lat]
        Seaports::Geometry::Candidates.around(args[:lat], args.fetch(:lng), radius_m: radius_km * 1000)
      else
        Seaports::Geometry::Candidates.around_port(locode, radius_km:)
      end
    FileUtils.mkdir_p("tmp/geometry")
    path = "tmp/geometry/#{locode}.candidates.json"
    earlier = args[:lat] && File.exist?(path) ? JSON.parse(File.read(path)) : []
    merged = (earlier + candidates.map { |c| c.to_h.transform_keys(&:to_s) }).uniq { |c| c["ref"] }
    File.write(path, JSON.pretty_generate(merged))
    puts "#{candidates.size} candidates in #{path}"
  end

  # Recurring: run it after editing a selection, and weekly from
  # .github/workflows/geometry.yml to pick up OpenStreetMap's edits. Builds
  # one port, or every port with a selection, and checks each against the
  # others already shipped, both ways. A port that fails keeps its old file,
  # and the task fails after trying the rest.
  desc "Build port outlines from data/geometry/sources and check them"
  task :geometry, [:locode] do |_task, args|
    require_relative "lib/seaports/geometry/builder"
    require_relative "lib/seaports/geometry/checks"

    builder_class = Seaports::Geometry::Builder
    checks = Seaports::Geometry::Checks
    locodes = args[:locode] ? [args[:locode].upcase] : Dir[File.join(builder_class::SOURCES_DIR, "*.yml")].map { |p| File.basename(p, ".yml") }.sort
    extract = osm_extract
    failed = []
    locodes.each do |locode|
      shapes = extract ? { shapes: extract.shapes_for(locode) } : {}
      collection = builder_class.new(builder_class.read_selection(builder_class.selection_path(locode)), **shapes).build
      others = geometry_collections.except(locode)
      result = checks.run(collection, others:, file_locode: locode)
      report_geometry(result)
      # Both ways: new limits that now swallow a neighbour's terminal are as
      # wrong as a terminal inside a neighbour's limits.
      swallowed = others.flat_map { |other, theirs| checks.run(theirs, others: { locode => collection }, file_locode: other).errors.grep(/inside #{locode}/) }
      swallowed.each { |line| puts "  error: #{line}" }
      next failed << locode unless result.ok? && swallowed.empty?

      File.write(builder_class.output_path(locode), "#{builder_class.dump(collection)}\n")
    # Any failure is this port's alone: a YAML typo, a deleted feature or an
    # Overpass outage must not cost the weekly run every port after it.
    rescue StandardError => e
      warn "#{locode}: #{e.class}: #{e.message}"
      failed << locode
    end
    abort "Not written: #{failed.join(', ')}" unless failed.empty?
  end

  # Recurring, and offline: geometry.yml asks it before fetching a port from
  # OpenStreetMap. Succeeds when the shipped outline was built from the
  # selection as it stands, and fails when it was not, or is missing.
  desc "Whether a port's outline was built from its current selection"
  task :geometry_current, [:locode] do |_task, args|
    require_relative "lib/seaports/geometry/builder"

    locode = args[:locode].to_s.upcase
    abort "#{locode}: the outline is missing or was built from another selection" unless Seaports::Geometry::Builder.current?(locode)

    puts "#{locode}: the outline was built from this selection"
  end

  # Recurring, and offline: what CI runs. The same checks over every shipped
  # file, plus that each has a selection it was built from.
  desc "Check every shipped port outline"
  task :check_geometry do
    require_relative "lib/seaports/geometry/builder"
    require_relative "lib/seaports/geometry/checks"

    collections = geometry_collections
    results = collections.map { |locode, collection| Seaports::Geometry::Checks.run(collection, others: collections, file_locode: locode) }
    results.each { |result| report_geometry(result) }
    orphans = collections.keys.reject { |locode| File.exist?(Seaports::Geometry::Builder.selection_path(locode)) }
    abort "No selection for #{orphans.join(', ')}" unless orphans.empty?

    # An outline must say what its selection says. A hand-edited GeoJSON (a
    # feature added, renamed or re-sourced without the selection) fails here.
    # A hand-moved coordinate does not: geometry.yml rebuilds from
    # OpenStreetMap an outline a pull request edits without its selection,
    # and the weekly run rebuilds them all.
    drift = collections.flat_map do |locode, collection|
      selection = Seaports::Geometry::Builder.read_selection(Seaports::Geometry::Builder.selection_path(locode))
      lines = Seaports::Geometry::Checks.drift(collection, selection)
      begin
        Seaports::Geometry::Builder.new(selection).check!
      rescue Seaports::Geometry::Builder::Invalid => e
        lines << "the selection fails its checks: #{e.message}"
      end
      # Catches what the comparison above cannot see, such as a changed
      # buffer_m, and an outline whose selection was edited without a rebuild.
      unless collection["selection_digest"] == Seaports::Geometry::Builder.digest(selection)
        lines << "the outline was not built from the selection as it stands: rebuild it with rake seaports:geometry[#{locode}]"
      end
      lines.map { |line| "#{locode}: #{line}" }
    end
    drift.each { |line| puts "  error: #{line}" }
    abort "Port outlines failed their checks" unless results.all?(&:ok?) && drift.empty?
  end

  # Where seaports:geometry reads OpenStreetMap from: the public Overpass API
  # (OSM_SOURCE unset or "overpass"), or Geofabrik extracts read with
  # osmium-tool on this machine (OSM_SOURCE=extract), which neither
  # rate-limits nor changes between two builds of the same day. With
  # extracts, OSM_REGION names one Geofabrik region to read every feature
  # from, and OSM_EXTRACT_MAX_AGE_DAYS how old a cached download may be.
  def osm_extract
    case ENV.fetch("OSM_SOURCE", "overpass")
    when "overpass" then nil
    when "extract"
      require_relative "lib/seaports/geometry/extract"
      Seaports::Geometry::Extract.new(region: ENV["OSM_REGION"],
        max_age_days: Float(ENV.fetch("OSM_EXTRACT_MAX_AGE_DAYS", Seaports::Geometry::Extract::MAX_AGE_DAYS)))
    else abort "OSM_SOURCE is overpass or extract, not #{ENV['OSM_SOURCE']}"
    end
  end

  def geometry_collections
    Dir[File.join(Seaports::Geometry::DIR, "*.geojson")].to_h { |path| [File.basename(path, ".geojson"), JSON.parse(File.read(path))] }
  end

  def report_geometry(result)
    puts "#{result.locode}: #{result.ok? ? 'ok' : 'FAILED'}"
    result.errors.each { |line| puts "  error: #{line}" }
    result.warnings.each { |line| puts "  warning: #{line}" }
  end
end
