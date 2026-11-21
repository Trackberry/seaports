# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "tmpdir"

require "set"

require_relative "alternate_names"
require_relative "builder"
require_relative "coordinate_sources"
require_relative "wikidata"
require_relative "wpi"

module Seaports
  # The weekly refresh of the two generated position files, as functions the
  # rake tasks call and the tests drive with stubs.
  #
  # Neither touches the shipped table: the UN/LOCODE rebuild runs after them
  # and merges what they wrote, so its gates (Seaports::Diff) judge the
  # coordinate changes together with everything else.
  #
  # Each works in a temporary directory and moves its files into place only
  # when everything has passed, so a failure at any step leaves the repository
  # as it was. Four outcomes: "changed" and "unchanged" are what they say;
  # "failed" is a source nobody could reach, a warning; "refused" is a source
  # that answered with something the gates would not accept, which a person
  # needs to look at.
  module CoordinateRefresh
    # More than this share of a file's existing positions moving over a
    # kilometre in one run is a source that reshuffled its codes, not ports
    # that were resurveyed.
    MAXIMUM_MOVED = 0.05
    MOVED_KM = 1
    NAMES_SHOWN = 60

    # A World Port Index that loses more than this share of the rows already
    # used (see dataset_losses) is a truncated or reorganised file.
    MAXIMUM_LOST = 0.02

    class Refused < StandardError; end

    # +names+ is the markdown for the pull request listing places whose name
    # differs between the dataset and the table, "" when there are none.
    Outcome = Data.define(:status, :line, :names)

    # Why a row may leave a generated file without the dataset having lost it:
    # UN/LOCODE publishes the port's position now, the code left the table, or
    # a higher-ranked source holds it. Anything else (gone from the dataset,
    # invalid, ambiguous, off its country) is the dataset's doing.
    LEGITIMATE_REMOVALS = %i[has_unlocode_position not_in_table held_by_other_source].freeze

    # The removed locodes the dataset itself lost, given Result#reasons.
    def self.dataset_losses(removed, reasons)
      removed.reject { |locode| LEGITIMATE_REMOVALS.include?(reasons[locode]) }
    end

    def self.guard!(label, change, maximum_lost: nil, reasons: {})
      return if change.before_size.zero?

      moved = change.moved.size.to_f / change.before_size
      if moved > MAXIMUM_MOVED
        raise Refused, "#{change.moved.size} of #{change.before_size} #{label} positions moved over #{MOVED_KM} km, past the #{(MAXIMUM_MOVED * 100).round}% limit"
      end

      lost = dataset_losses(change.removed, reasons)
      return unless maximum_lost && lost.size.to_f / change.before_size > maximum_lost

      raise Refused, "#{lost.size} of #{change.before_size} #{label} rows would be lost by the dataset, past the #{(maximum_lost * 100).round}% limit"
    end

    # Moves each staged file over its destination, and puts back whatever it
    # replaced if one of the moves fails.
    def self.install(stage, moves)
      backups = {}
      done = []
      moves.each_value.with_index do |to, index|
        next unless File.exist?(to)

        backups[to] = File.join(stage, "backup-#{index}")
        FileUtils.cp(to, backups[to])
      end
      moves.each do |from, to|
        FileUtils.mkdir_p(File.dirname(to))
        FileUtils.mv(from, to)
        done << to
      end
    rescue StandardError
      done.each { |to| backups[to] ? FileUtils.cp(backups[to], to) : FileUtils.rm_f(to) }
      raise
    end

    def self.name_report(mismatches)
      return "" if mismatches.empty?

      shown = mismatches.first(NAMES_SHOWN).map { |locode, theirs, ours| "- `#{locode}` World Port Index “#{theirs}”, table “#{ours}”" }
      shown << "- …and #{mismatches.size - NAMES_SHOWN} more" if mismatches.size > NAMES_SHOWN
      "Names that differ between the World Port Index and UN/LOCODE (#{mismatches.size}), in case a code names another place:\n\n#{shown.join("\n")}"
    end

    # Fetches the newest World Port Index (or takes +download+) and regenerates
    # its coordinates. See the module comment for the outcomes.
    def self.refresh_wpi(download: nil, http: Http.method(:get), **options)
      download ||= Wpi.fetch_latest(http:)
      wpi(download, **options)
    rescue Wpi::Unavailable => e
      Outcome.new("failed", "World Port Index: not refreshed, left as it was (#{e.message}).", "")
    rescue Wpi::Invalid, Refused => e
      Outcome.new("refused", "World Port Index: refused, left as it was (#{e.message}).", "")
    rescue StandardError => e
      Outcome.new("failed", "World Port Index: not refreshed, left as it was (#{e.class}: #{e.message}).", "")
    end

    def self.wpi(download, boundaries: nil, table: CoordinateSources.table, held: Builder.coordinate_overrides.keys,
      csv_path: Wpi::CSV_PATH, provenance_path: Wpi::PROVENANCE_PATH, coordinates_path: Builder::WPI_COORDINATES_PATH,
      alternate_names_path: Builder::WPI_ALTERNATE_NAMES_PATH, today: Date.today)
      vendored =File.exist?(csv_path) ? File.read(csv_path) : nil
      Wpi.validate!(download.text, vendored:)

      # An older copy than the one vendored (an archive snapshot, after NGA
      # was reached once) would flip the file back and forth between runs.
      current = Wpi.provenance(provenance_path)["snapshot"]
      if current && download.snapshot < current
        raise Refused, "the download is the #{download.snapshot} edition, older than the vendored #{current}"
      end

      boundaries = boundaries.call if boundaries.respond_to?(:call)

      replaced = vendored.nil? || Wpi.sha256(vendored) != Wpi.sha256(download.text)
      provenance = replaced ? Wpi.provenance_for(download, today) : Wpi.provenance(provenance_path)
      text = Wpi.normalize(download.text)
      result = CoordinateSources.select(Wpi.candidates(text, source: Wpi.source_label(provenance.fetch("snapshot"))),
        table:, held:, boundaries:)
      change = CoordinateSources.change(CoordinateSources.points(coordinates_path), result.rows.to_h { |row| [row[0], row.values_at(2, 3)] })
      guard!("World Port Index", change, maximum_lost: MAXIMUM_LOST, reasons: result.reasons)

      # The alternate names come from the same file under the same checks: the
      # port must be in the table, and a locode on several index rows is
      # skipped. A names file is not a position, so it has no move or loss
      # guard; the table diff and the pull request show what changed.
      alternate_rows, alternate_counts = AlternateNames.select(Wpi.alternate_candidates(text), ports: table.keys.to_set,
        source: Wpi.source_label(provenance.fetch("snapshot")))

      Dir.mktmpdir("seaports-wpi") do |stage|
        staged = { csv: File.join(stage, "UpdatedPub150.csv"), provenance: File.join(stage, "provenance.json"),
                   coordinates: File.join(stage, "coordinates_wpi.csv"), alternate_names: File.join(stage, "alternate_names_wpi.csv") }
        File.write(staged[:csv], text)
        File.write(staged[:provenance], "#{JSON.pretty_generate(provenance)}\n")
        CoordinateSources.write(staged[:coordinates], result.rows)
        AlternateNames.write(staged[:alternate_names], alternate_rows)

        moves = {}
        moves[staged[:csv]] = csv_path if replaced
        moves[staged[:provenance]] = provenance_path if replaced
        coordinates_changed = !File.exist?(coordinates_path) || File.read(coordinates_path) != File.read(staged[:coordinates])
        moves[staged[:coordinates]] = coordinates_path if coordinates_changed
        names_changed = !File.exist?(alternate_names_path) || File.read(alternate_names_path) != File.read(staged[:alternate_names])
        moves[staged[:alternate_names]] = alternate_names_path if names_changed
        install(stage, moves) unless moves.empty?

        line = CoordinateSources.summary("World Port Index (snapshot #{provenance['snapshot']})", change, result.rows.size, result.counts)
        skipped = alternate_counts.except(:ports).map { |reason, n| "#{n} #{reason.to_s.tr('_', ' ')}" }
        line += " Alternate names: #{alternate_counts.fetch(:ports, 0)} ports, skipped: #{skipped.empty? ? 'none' : skipped.join(', ')}."
        line += " The vendored index was replaced (#{download.via}, #{download.url})." if replaced
        Outcome.new(moves.empty? ? "unchanged" : "changed", line, name_report(result.mismatches))
      end
    end

    # Queries Wikidata (or takes +hits+) and regenerates its coordinates.
    def self.refresh_wikidata(hits: nil, http: Http.method(:get), **options)
      hits ||= Wikidata.fetch_hits(http:)
      wikidata(hits, **options)
    rescue Refused => e
      Outcome.new("refused", "Wikidata: refused, left as it was (#{e.message}).", "")
    rescue StandardError => e
      Outcome.new("failed", "Wikidata: not refreshed, left as it was (#{e.class}: #{e.message}).", "")
    end

    def self.wikidata(hits, boundaries: nil, table: CoordinateSources.table,
      held: Builder.coordinate_overrides.keys + Builder.coordinate_overrides(Builder::WPI_COORDINATES_PATH).keys,
      coordinates_path: Builder::WIKIDATA_COORDINATES_PATH, provenance_path: Wikidata::PROVENANCE_PATH, today: Date.today)
      boundaries = boundaries.call if boundaries.respond_to?(:call)
      seen = hits.map(&:locode).uniq.size
      minimum = Wikidata::EXPECTED_CODES * Wikidata::MINIMUM_SHARE
      raise Refused, "Wikidata answered with only #{seen} codes, fewer than #{minimum.to_i}" if seen < minimum

      candidates, stats = Wikidata.candidates(hits)
      result = CoordinateSources.select(candidates, table:, held:, boundaries:)
      change = CoordinateSources.change(CoordinateSources.points(coordinates_path), result.rows.to_h { |row| [row[0], row.values_at(2, 3)] })
      guard!("Wikidata", change, maximum_lost: Wikidata::MAXIMUM_LOST, reasons: result.reasons)

      Dir.mktmpdir("seaports-wikidata") do |stage|
        staged = File.join(stage, "coordinates_wikidata.csv")
        CoordinateSources.write(staged, result.rows)
        changed = !File.exist?(coordinates_path) || File.read(coordinates_path) != File.read(staged)
        if changed
          # The retrieval date is written only with a change, or the file would
          # differ every week and open a pull request about nothing.
          note = File.join(stage, "provenance.json")
          File.write(note, "#{JSON.pretty_generate('source' => 'Wikidata (CC0), P1937 with P625', 'retrieved_on' => today.iso8601,
            'codes_seen' => seen, 'rows' => result.rows.size)}\n")
          install(stage, { staged => coordinates_path, note => provenance_path })
        end

        counts = result.counts.merge(not_port_typed_on_wikidata: stats[:not_port_typed], ambiguous_on_wikidata: stats[:ambiguous]).reject { |_, n| n.zero? }
        line = CoordinateSources.summary("Wikidata", change, result.rows.size, counts)
        Outcome.new(changed ? "changed" : "unchanged", line, "")
      end
    end

    # The status the workflow acts on, from the table diff and not from the
    # source files: "ok" when the shipped table changed (a release), "sources"
    # when only the generated files did (a pull request, no release), "failed"
    # when the table fails its gates, "unchanged" otherwise.
    def self.release_status(diff, sources_changed:)
      return "failed" unless diff.ok?
      return "ok" if diff.changed?

      sources_changed ? "sources" : "unchanged"
    end
  end
end
