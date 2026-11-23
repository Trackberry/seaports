# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.25"
gem "rake", "~> 13.2"
gem "rubocop-rails-omakase", require: false

# Build time only: Geometry::Clip cuts derived port limits to the water with
# GEOS (brew install geos, apt-get install libgeos-dev). The gem itself never
# loads it: the outlines are built once and shipped as GeoJSON.
gem "ffi-geos", "~> 2.5", require: false
