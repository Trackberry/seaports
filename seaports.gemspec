# frozen_string_literal: true

require_relative "lib/seaports/version"

Gem::Specification.new do |spec|
  spec.name = "seaports"
  spec.version = Seaports::VERSION
  spec.authors = ["Édouard Brière"]
  spec.email = ["edouard.briere@gmail.com"]

  spec.summary = "UN/LOCODE sea ports: a locode in, a port name and position out."
  spec.description = <<~TEXT
    Every sea port UNECE publishes a UN/LOCODE for, as a lookup table with no
    dependencies and no network calls. Turns the bare codes in an AIS or
    carrier tracking feed back into port names and coordinates. The table is
    regenerated from each UN/LOCODE release and shipped inside the gem.
  TEXT
  spec.homepage = "https://github.com/Trackberry/seaports"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "data/*.csv", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  # The only dependency, and only because Ruby 3.4 demoted csv out of the
  # default gems: under Bundler it now has to be asked for by name.
  spec.add_dependency "csv", "~> 3.3"
end
