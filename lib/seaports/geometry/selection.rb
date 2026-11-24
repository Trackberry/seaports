# frozen_string_literal: true

require "date"
require "yaml"

require_relative "../geometry"

module Seaports
  module Geometry
    # A port's selection file, data/geometry/sources/<LOCODE>.yml, as data:
    # read, written in one canonical form, and changed by a list of edits.
    #
    # The canonical form is what makes an edit reviewable. Every selection is
    # written by Selection.dump, so an edit made by a program (a reader's
    # correction, an agent's draft) changes the lines it means to and no
    # others. That is also why the files carry no YAML comments: a comment
    # would not survive a rewrite, so what a person would say in one goes in a
    # +note+.
    #
    # Edits name features by their OpenStreetMap references, never by
    # coordinates. An edit may add a feature only from the references it is
    # told exist (+known_refs+: what Candidates found near a reader's pin),
    # which keeps the rule that no shape is typed or generated.
    module Selection
      TOP_KEYS = %w[locode reviewed_at note quays position_outside port_limits features].freeze
      LIMIT_KEYS = %w[derive osm buffer_m clip disjoint exclude note accepts].freeze
      # Each area taken out of the limits: its reference and why.
      EXCLUDE_KEYS = %w[osm why].freeze
      # What the reviewers accepted inside the limits (Inside.compare).
      ACCEPT_KEYS = %w[houses residential_m2 amenities places].freeze
      FEATURE_KEYS = %w[osm kind name operator cargo category buffer_m inland note reviewed_at].freeze
      EDITABLE = %w[kind name operator cargo category note].freeze
      TEXT_LIMITS = { "name" => 120, "operator" => 120, "note" => 600 }.freeze

      class Invalid < StandardError; end

      module_function

      def load(text)
        data = YAML.safe_load(text, permitted_classes: [Date])
        raise Invalid, "a selection is a mapping" unless data.is_a?(Hash)

        data
      end

      # Keys in a fixed order, dates as ISO strings, a feature's single
      # reference as a string and several as a list. +top_keys+ and
      # +feature_keys+ give the order for another kind of selection: a
      # canal's (Canal::Builder) has no limits or quays, and its anchorages
      # say which approach they serve.
      def dump(selection, top_keys: TOP_KEYS, feature_keys: FEATURE_KEYS)
        canonical = top_keys.filter_map do |key|
          value = selection[key]
          next if value.nil? || value == []

          [key, canonical_value(key, value, feature_keys)]
        end.to_h
        canonical.to_yaml(line_width: 100)
      end

      # Applies +edits+ to a copy of +selection+ and answers it. Each edit is a
      # Hash with "op":
      #
      #   { "op" => "update", "osm" => "way/1", "set" => { "cargo" => ["reefer"] } }
      #   { "op" => "add", "osm" => ["way/2"], "kind" => "terminal", "name" => ..., ... }
      #   { "op" => "remove", "osm" => "way/1" }
      #   { "op" => "quays", "add" => ["NLBOT"], "remove" => [] }
      #
      # "osm" names an existing feature by any of its references. Raises
      # Invalid, changing nothing, at the first edit that does not apply.
      def apply(selection, edits, known_refs: [], reviewed_at: Date.today)
        result = deep_copy(selection)
        result["features"] ||= []
        Array(edits).each { |edit| apply_one(result, edit, known_refs.map(&:to_s)) }
        result["reviewed_at"] = reviewed_at.iso8601 if reviewed_at
        result
      end

      def apply_one(selection, edit, known_refs)
        raise Invalid, "an edit is a mapping" unless edit.is_a?(Hash)

        case edit["op"]
        when "update" then update(selection, edit)
        when "add" then add(selection, edit, known_refs)
        when "remove" then remove(selection, edit)
        when "quays" then quays(selection, edit)
        else raise Invalid, "unknown edit #{edit['op'].inspect}"
        end
      end

      def update(selection, edit)
        feature = find!(selection, edit["osm"])
        changes = edit["set"]
        raise Invalid, "update #{edit['osm']}: nothing to set" unless changes.is_a?(Hash) && !changes.empty?

        unknown = changes.keys - EDITABLE
        raise Invalid, "update #{edit['osm']}: cannot set #{unknown.join(', ')}" unless unknown.empty?

        changes.each do |key, value|
          value.nil? || value == "" || value == [] ? feature.delete(key) : feature[key] = clean(key, value)
        end
        check_feature!(feature)
      end

      def add(selection, edit, known_refs)
        refs = Array(edit["osm"]).map(&:to_s)
        raise Invalid, "add: no osm reference" if refs.empty?

        unknown = refs - known_refs
        raise Invalid, "add: #{unknown.join(', ')} is not among the features found" unless unknown.empty?

        taken = refs.select { |ref| feature_for(selection, ref) }
        raise Invalid, "add: #{taken.join(', ')} is already in the selection" unless taken.empty?

        feature = { "osm" => refs.size == 1 ? refs.first : refs }
        EDITABLE.each { |key| feature[key] = clean(key, edit[key]) unless edit[key].nil? || edit[key] == "" }
        check_feature!(feature)
        selection["features"] << feature
      end

      def remove(selection, edit)
        feature = find!(selection, edit["osm"])
        selection["features"].delete(feature)
      end

      def quays(selection, edit)
        list = Array(selection["quays"]) + Array(edit["add"]).map { |code| code.to_s.upcase }
        list -= Array(edit["remove"]).map { |code| code.to_s.upcase }
        bad = list.reject { |code| code.match?(/\A[A-Z]{2}[A-Z0-9]{3}\z/) }
        raise Invalid, "quays: #{bad.join(', ')} is not a locode" unless bad.empty?

        selection["quays"] = list.uniq.sort
      end

      def find!(selection, ref)
        feature_for(selection, ref.to_s) or raise Invalid, "no feature #{ref.inspect} in #{selection['locode']}"
      end

      def feature_for(selection, ref)
        Array(selection["features"]).find { |feature| Array(feature["osm"]).map(&:to_s).include?(ref) }
      end

      def check_feature!(feature)
        unless (KINDS - ["port_limits"]).include?(feature["kind"])
          raise Invalid, "#{feature['osm']}: kind #{feature['kind'].inspect} is not one of #{(KINDS - ['port_limits']).join(', ')}"
        end

        bad = Array(feature["cargo"]) - CARGO
        raise Invalid, "#{feature['osm']}: cargo #{bad.join(', ')} is not one of #{CARGO.join(', ')}" unless bad.empty?
        return if feature["category"].nil? || ANCHORAGE_CATEGORIES.include?(feature["category"])

        raise Invalid, "#{feature['osm']}: category #{feature['category']} is not one of #{ANCHORAGE_CATEGORIES.join(', ')}"
      end

      # Text from a reader or a model: one line, no control characters, and
      # short. cargo is a list of codes, whatever shape it arrived in.
      def clean(key, value)
        return Array(value).map { |code| code.to_s.strip.downcase }.uniq if key == "cargo"
        return value.to_s.strip.downcase if %w[kind category].include?(key)

        text = value.to_s.gsub(/[[:cntrl:]]+/, " ").squeeze(" ").strip
        limit = TEXT_LIMITS.fetch(key, 200)
        text.length > limit ? "#{text[0, limit - 1].rstrip}…" : text
      end

      def canonical_value(key, value, feature_keys = FEATURE_KEYS)
        case key
        when "reviewed_at" then value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
        when "port_limits"
          limits = ordered(value, LIMIT_KEYS)
          limits["accepts"] = ordered(limits["accepts"], ACCEPT_KEYS) if limits["accepts"].is_a?(Hash)
          limits.delete("accepts") if limits["accepts"] == {}
          limits["exclude"] = limits["exclude"].map { |entry| entry.is_a?(Hash) ? ordered(entry, EXCLUDE_KEYS) : entry } if limits["exclude"].is_a?(Array)
          limits
        when "features" then value.map { |feature| ordered(feature, feature_keys) }
        when "ends" then value.is_a?(Hash) ? value.sort.to_h : value
        else value
        end
      end

      def ordered(hash, keys)
        keys.filter_map do |key|
          value = hash[key]
          next if value.nil? || value == []

          value = value.iso8601 if value.respond_to?(:iso8601)
          value = value.first if key == "osm" && value.is_a?(Array) && value.size == 1
          [key, value]
        end.to_h
      end

      def deep_copy(value) = Marshal.load(Marshal.dump(value))
    end
  end
end
