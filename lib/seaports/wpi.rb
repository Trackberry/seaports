# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "timeout"
require "uri"
require "zlib"

require_relative "alternate_names"
require_relative "coordinate_sources"
require_relative "http"

module Seaports
  # The NGA World Port Index (Pub. 150): about 3,800 ports with a position and,
  # for most, a UN/LOCODE. A work of the US government, so in the public domain;
  # NGA asks only that it be credited.
  #
  # A copy is vendored in data/sources/wpi/ with a provenance note, so a build
  # does not depend on NGA being up, and its sha256 says when the copy changed.
  # `rake seaports:refresh_wpi` looks for a newer one: NGA first, and the
  # Internet Archive's newest snapshot of NGA's URL when NGA answers with its
  # maintenance page, which it has been doing for weeks at a time.
  class Wpi
    # A file in hand that is not the index.
    class Invalid < StandardError; end

    # Neither NGA nor the archive could produce a file at all: an outage, not a
    # bad file.
    class Unavailable < StandardError; end

    SOURCE_URL = "https://msi.nga.mil/api/publications/download?type=view&key=16920959%2FSFH00000%2FUpdatedPub150.csv"
    CDX_URL = "https://web.archive.org/cdx/search/cdx"
    DIRECTORY = File.expand_path("../../data/sources/wpi", __dir__)
    CSV_PATH = File.join(DIRECTORY, "UpdatedPub150.csv")
    PROVENANCE_PATH = File.join(DIRECTORY, "provenance.json")

    REQUIRED_COLUMNS = ["World Port Index Number", "Main Port Name", "UN/LOCODE", "Country Code", "Latitude", "Longitude"].freeze
    # A file this far from the vendored one's size is a truncated download or a
    # different document, not a new edition. The index changes by a handful of
    # ports a year.
    ROW_TOLERANCE = 0.05
    # A port that must be there, for a file that parses but is not the index.
    CANARY = "IEORK"

    Download = Data.define(:text, :url, :snapshot, :via)

    # The text without a byte order mark or Windows line endings, which is
    # what is stored and hashed: the same index saved by a different tool is
    # not a change.
    def self.normalize(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿").gsub("\r\n", "\n").strip << "\n"
    end

    def self.sha256(text)
      Digest::SHA256.hexdigest(normalize(text))
    end

    def self.header?(text)
      first = normalize(text).lines.first.to_s
      REQUIRED_COLUMNS.all? { |column| first.include?(column) }
    end

    # Bytes to text: gunzipped when the archive handed over the stored gzip.
    def self.decode(body)
      body = body.to_s.b
      body = Zlib::GzipReader.new(StringIO.new(body)).read if body.start_with?("\x1F\x8B".b)
      body.force_encoding(Encoding::UTF_8)
    rescue Zlib::Error
      "".dup
    end

    # The newest WPI CSV that can be had, from NGA or else the Internet
    # Archive. Only something that starts like the index is accepted, never the
    # HTML page NGA serves in maintenance. +http+ is Seaports::Http.get-shaped.
    # Raises Unavailable when neither has one.
    def self.fetch_latest(http: Http.method(:get))
      nga = begin
        status, body, = http.call(SOURCE_URL, {})
        text = status == 200 ? decode(body) : nil
        return Download.new(text:, url: SOURCE_URL, snapshot: Date.today.iso8601, via: "NGA") if text && header?(text)

        status == 200 ? "an answer that is not the index" : "HTTP #{status}"
      rescue StandardError => e
        "#{e.class}"
      end

      from_wayback(http).tap { |download| warn "NGA answered with #{nga}; using the Internet Archive snapshot of #{download.snapshot}." }
    end

    def self.from_wayback(http)
      query = "#{CDX_URL}?#{URI.encode_www_form(url: SOURCE_URL, output: 'json', fl: 'timestamp,original', filter: 'statuscode:200', limit: -6)}"
      status, body, = http.call(query, {})
      raise Unavailable, "NGA is unavailable and the Internet Archive's index answered HTTP #{status}" unless status == 200

      snapshots = JSON.parse(body).drop(1).reverse
      raise Unavailable, "NGA is unavailable and the Internet Archive has no snapshot of the index" if snapshots.empty?

      snapshots.each do |timestamp, original|
        url = "https://web.archive.org/web/#{timestamp}id_/#{original}"
        code, raw, = http.call(url, {})
        text = code == 200 ? decode(raw) : nil
        next unless text && header?(text)

        return Download.new(text:, url:, snapshot: Date.strptime(timestamp[0, 8], "%Y%m%d").iso8601, via: "the Internet Archive")
      end
      raise Unavailable, "NGA is unavailable and none of the Internet Archive's newest #{snapshots.size} snapshots is the index"
    rescue JSON::ParserError, Net::ProtocolError, SystemCallError, SocketError, Timeout::Error, Http::TooLarge => e
      raise Unavailable, "NGA is unavailable and the Internet Archive could not be read (#{e.class})"
    end

    # Raises Invalid, naming the first thing wrong. +vendored+ is the text to
    # compare the size with; without one the size is not checked.
    def self.validate!(text, vendored: nil)
      raise Invalid, "the file does not have the World Port Index columns (#{REQUIRED_COLUMNS.join(', ')})" unless header?(text)

      table = begin
        CSV.parse(normalize(text))
      rescue CSV::MalformedCSVError => e
        raise Invalid, "the file is not well-formed CSV (#{e.message})"
      end
      # A download cut off mid-row ends in a short line: the cheapest sign of
      # truncation that a row count inside the tolerance would not catch.
      raise Invalid, "the last row has #{table.last.size} fields, the header #{table.first.size}: the file looks truncated" if table.last.size < table.first.size

      rows = rows(text)
      raise Invalid, "the file has no UN/LOCODE for Cork (#{CANARY})" unless rows.any? { |row| locode_of(row) == CANARY }

      if vendored
        expected = rows(vendored).size
        unless rows.size.between?(expected * (1 - ROW_TOLERANCE), expected * (1 + ROW_TOLERANCE))
          raise Invalid, "the file has #{rows.size} rows, #{expected} expected give or take #{(ROW_TOLERANCE * 100).to_i}%"
        end
      end
      rows.size
    end

    def self.rows(text)
      CSV.parse(normalize(text), headers: true).map(&:to_h)
    end

    def self.locode_of(row)
      row["UN/LOCODE"].to_s.delete(" ").upcase
    end

    # Candidates for CoordinateSources.select, from a World Port Index CSV.
    def self.candidates(text, source:)
      rows(text).map do |row|
        CoordinateSources::Candidate.new(locode: locode_of(row), name: row["Main Port Name"], lat: row["Latitude"],
          lng: row["Longitude"], source:)
      end
    end

    # [locode, "Antwerp; Anvers"] per row with a valid-looking locode, for
    # AlternateNames.select. A row without a locode cannot be placed.
    def self.alternate_candidates(text)
      rows(text).filter_map do |row|
        locode = locode_of(row)
        [locode, row["Alternate Port Name"]] if locode.match?(AlternateNames::LOCODE)
      end
    end

    def self.source_label(snapshot)
      "NGA World Port Index (Pub. 150), snapshot #{snapshot}"
    end

    def self.provenance(path = PROVENANCE_PATH)
      File.exist?(path) ? JSON.parse(File.read(path)) : {}
    end

    # What provenance.json says about +download+.
    def self.provenance_for(download, today = Date.today)
      {
        "source" => "NGA World Port Index (Pub. 150), UpdatedPub150.csv",
        "licence" => "Public domain (a work of the US government); attribution to NGA recommended",
        "nga_url" => SOURCE_URL,
        "retrieved_from" => download.url,
        "retrieved_via" => download.via,
        "snapshot" => download.snapshot,
        "retrieved_on" => today.iso8601,
        "sha256" => sha256(download.text),
        "rows" => rows(download.text).size
      }
    end
  end
end
