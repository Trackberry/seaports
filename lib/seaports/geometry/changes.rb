# frozen_string_literal: true

require "json"

require_relative "../../seaports"

module Seaports
  module Geometry
    # What the weekly rebuild moved, port by port, for the changelog entry and
    # the pull request: which features were added, removed or changed between
    # two copies of the shipped outlines.
    #
    # A feature is known by its kind and the OpenStreetMap ids it was built
    # from, which is what its selection names, so a terminal whose quay was
    # redrawn, or renamed, is "changed" rather than one removed and one added.
    # Its label is its name, or its kind for an unnamed one ("the port
    # limits").
    #
    # The collection's own fields count too (its quays, position_outside, the
    # selection digest): a rebuild that changes only those still changed what
    # the gem ships, so the port is listed ("the outline's quays changed")
    # and released like any other.
    module Changes
      # One port's or canal's changes: +id+ is its locode (NLRTM) or canal id
      # (suez), each list holds feature labels, and +fields+ the collection
      # fields that differ.
      Port = Data.define(:id, :name, :added, :removed, :changed, :fields) do
        def empty? = added.empty? && removed.empty? && changed.empty? && fields.empty?

        # "Rotterdam (`NLRTM`): Euromax Terminal and the port limits changed; Anchorage 4 added."
        def line
          parts = { "changed" => changed, "added" => added, "removed" => removed }.filter_map do |verb, labels|
            "#{Changes.sentence(labels)} #{verb}" unless labels.empty?
          end
          parts << "the outline's #{Changes.sentence(fields.map { |field| field.tr('_', ' ') })} changed" unless fields.empty?
          "#{name} (`#{id}`): #{parts.join('; ')}."
        end
      end

      module_function

      # +before+ and +after+ are { id => collection, or nil when the file
      # does not exist }; an id in only one of them counts as nil in the
      # other. Ports with no change are left out, and the rest come in id
      # order.
      def between(before, after, names: {})
        (before.keys | after.keys).sort.filter_map do |id|
          old = features(before[id])
          new = features(after[id])
          port = Port.new(id:, name: names[id] || collection_name(after[id] || before[id]) || id,
            added: labels(new.keys - old.keys, new), removed: labels(old.keys - new.keys, old),
            changed: labels((old.keys & new.keys).reject { |key| old[key] == new[key] }, new),
            fields: fields(before[id], after[id]))
          port unless port.empty?
        end
      end

      # The collection fields other than its features that differ, when the
      # port is on both sides; one on a side only is all added or removed.
      def fields(old, new)
        return [] unless old && new

        ((old.keys | new.keys) - ["features"]).sort.reject { |key| old[key] == new[key] }
      end

      # { [kind, ids] => [feature, ...] }: a feature renamed or redrawn keeps
      # its key. Two built from the same ids (which a selection does not
      # allow) would share one, so each key holds a list.
      def features(collection)
        return {} unless collection

        collection.fetch("features", []).group_by do |feature|
          properties = feature["properties"] || {}
          [properties["kind"], Array(properties["osm"]).sort]
        end
      end

      def labels(keys, features)
        keys.flat_map { |key| features[key].map { |feature| label(feature) } }.uniq
      end

      def label(feature)
        properties = feature["properties"] || {}
        properties["name"] || "the #{properties['kind'].to_s.tr('_', ' ')}"
      end

      # A canal's collection carries its name; a port's does not, and the
      # caller passes the table's.
      def collection_name(collection) = collection && collection["name"]

      # "a", "a and b", "a, b and c".
      def sentence(labels)
        return labels.join if labels.size < 2

        "#{labels[0..-2].join(', ')} and #{labels.last}"
      end

      # The changelog entry for a release of these changes.
      def changelog(version, date, ports)
        ["## #{version} — #{date}", "",
          "Port outlines refreshed from OpenStreetMap by the weekly rebuild. What moved, port by port:", "",
          *ports.map { |port| "- #{port.line}" }]
      end

      # What rake seaports:geometry_release does after the weekly rebuild:
      # compares the outlines on disk with +read_before+'s (a callable that
      # takes a path relative to the repository and answers the committed
      # text, or nil), and when any moved, bumps the patch version from the
      # one checked out and writes the changelog entry. Leaves its decision in
      # +out_dir+ for the workflow, as seaports:refresh does: status (ok or
      # unchanged), version and summary.md.
      def perform(read_before:, root: File.expand_path("../../..", __dir__), out_dir: "tmp/geometry_refresh",
        version: Seaports::VERSION, date: Date.today, release: {})
        require "date"
        require "fileutils"
        require_relative "../release"

        paths = Dir[File.join(root, "data/geometry/*.geojson")] + Dir[File.join(root, "data/geometry/canals/*.geojson")]
        relative = paths.map { |path| path.delete_prefix("#{root}/") }.sort
        before = relative.to_h { |path| [File.basename(path, ".geojson"), (text = read_before.call(path)) && JSON.parse(text)] }
        after = relative.to_h { |path| [File.basename(path, ".geojson"), JSON.parse(File.read(File.join(root, path)))] }
        names = after.keys.to_h { |id| [id, Seaports.find(id)&.name] }.compact
        ports = between(before, after, names:)

        FileUtils.mkdir_p(out_dir)
        if ports.empty?
          File.write(File.join(out_dir, "status"), "unchanged\n")
          File.write(File.join(out_dir, "summary.md"), "No port outline moved.\n")
          return ports
        end

        next_version = Release.next_version(version, :patch)
        Release.write_version(next_version, **release.slice(:version_path, :lockfile_path))
        Release.write_changelog(changelog(next_version, date, ports), **release.slice(:path))
        File.write(File.join(out_dir, "status"), "ok\n")
        File.write(File.join(out_dir, "version"), "#{next_version}\n")
        File.write(File.join(out_dir, "summary.md"), summary(next_version, ports))
        ports
      end

      # The pull request body: the same list, and what merging does.
      def summary(version, ports)
        <<~MARKDOWN
          The weekly rebuild of `data/geometry` from the OpenStreetMap features each selection names. The diff has one feature per line, so it shows which terminals and anchorages moved.

          Merging releases **#{version}** (a patch: the outlines changed, the table did not). What moved:

          #{ports.map { |port| "- #{port.line}" }.join("\n")}
        MARKDOWN
      end
    end
  end
end
