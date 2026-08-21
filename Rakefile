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
  task :refresh, [:source, :release] do |_task, args|
    require_relative "lib/seaports/builder"
    require_relative "lib/seaports/diff"
    require "fileutils"

    FileUtils.mkdir_p(REFRESH_DIR)
    before = File.join(REFRESH_DIR, "before.csv")
    FileUtils.cp(Seaports::TABLE_PATH, before)

    source = Seaports::Builder.fetch(args[:source] || Seaports::Builder::SOURCE_URL)
    Seaports::Builder.new(source).write(Seaports::TABLE_PATH)

    diff = Seaports::Diff.between(before, Seaports::TABLE_PATH)
    File.write(File.join(REFRESH_DIR, "summary.md"), "#{diff.summary}\n")

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

    content = File.read(path).sub(/VERSION = "[^"]*"/, %(VERSION = "#{version}"))
    content = content.sub(/DATA_RELEASE = "[^"]*"/, %(DATA_RELEASE = "#{release}")) if release
    File.write(path, content)

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
