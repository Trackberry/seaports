# frozen_string_literal: true

require_relative "version"

module Seaports
  # The files a release changes, for the weekly jobs that open one: the
  # UN/LOCODE refresh (a minor version) and the port outline refresh (a
  # patch). Each reads the version it bumps from the checkout it runs in,
  # which is main as it stood when the job started; see the README's
  # "Releases from the weekly jobs" for what happens when both run on one
  # Monday.
  module Release
    VERSION_PATH = File.expand_path("version.rb", __dir__)
    LOCKFILE_PATH = File.expand_path("../../Gemfile.lock", __dir__)
    CHANGELOG_PATH = File.expand_path("../../CHANGELOG.md", __dir__)

    module_function

    # The version after +version+ at +level+, :minor or :patch.
    def next_version(version, level)
      major, minor, patch = version.split(".").map(&:to_i)
      case level
      when :minor then "#{major}.#{minor + 1}.0"
      when :patch then "#{major}.#{minor}.#{patch + 1}"
      else raise ArgumentError, "a release is :minor or :patch, not #{level.inspect}"
      end
    end

    # Gemfile.lock names this gem's own version twice (under PATH and under
    # CHECKSUMS), and bundler refuses a lockfile that disagrees with the
    # gemspec in a frozen install, which is how CI installs.
    def stamp_lockfile(content, version)
      content.gsub(/^(\s+)seaports \([^)]*\)$/) { "#{Regexp.last_match(1)}seaports (#{version})" }
    end

    # +entry+ (lines, starting with its "## " heading) above the newest entry.
    def prepend_changelog(content, entry)
      raise ArgumentError, "the changelog has no entry to write above" unless content.include?("\n## ")

      content.sub(/\n## /, "\n#{entry.join("\n")}\n\n## ")
    end

    # Writes +version+ into version.rb (through +stamp+, which takes the
    # file's text and answers the new text) and Gemfile.lock.
    def write_version(version, stamp: ->(text) { text.sub(/VERSION = "[^"]*"/, %(VERSION = "#{version}")) },
      version_path: VERSION_PATH, lockfile_path: LOCKFILE_PATH)
      File.write(version_path, stamp.call(File.read(version_path)))
      File.write(lockfile_path, stamp_lockfile(File.read(lockfile_path), version)) if File.exist?(lockfile_path)
      version
    end

    def write_changelog(entry, path: CHANGELOG_PATH)
      File.write(path, prepend_changelog(File.read(path), entry))
    end
  end
end
