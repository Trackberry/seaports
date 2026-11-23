# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "minitest", "~> 5.25"
gem "rake", "~> 13.2"
gem "rubocop-rails-omakase", require: false

# Build time only: Geometry::Clip cuts derived port limits to the water with
# GEOS through rgeo's C extension (brew install geos, apt-get install
# libgeos-dev, before bundle install). The gem itself never
# loads it: the outlines are built once and shipped as GeoJSON.
gem "rgeo", "~> 3.1", require: false
