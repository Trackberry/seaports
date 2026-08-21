# Seaports

[![CI](https://github.com/Trackberry/seaports/actions/workflows/ci.yml/badge.svg)](https://github.com/Trackberry/seaports/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/seaports)](https://rubygems.org/gems/seaports)

A locode in, a port name and a position out.

```ruby
Seaports.name("CNXMG")         # => "Xiamen Pt"
Seaports.coordinates("AUBNE")  # => { "lat" => -27.4667, "lng" => 153.0167 }
Seaports.find("KRPUS")         # => #<data Seaports::Port locode="KRPUS", name="Busan", ...>
```

Tracking feeds speak in codes. An AIS provider names some port calls and sends
only a code for the rest, so a stop that mattered arrives as a bare `XMG` — a
real, load-bearing fact about a voyage, written in a vocabulary nobody reads.
UNECE publishes the table that turns it back into `Xiamen Pt`, and publishes
coordinates alongside, so one dataset answers both *where is this?* and *where
do I draw it?*

## Install

```ruby
gem "seaports"
```

Ruby 3.2 or newer. One dependency, `csv`, and only because Ruby 3.4 demoted it
out of the default gems.

## What is in it

Every entry UN/LOCODE classifies as a sea port: **17,520 ports**, 11,762 of them
with published coordinates, built from **UN/LOCODE 2024-2**.

```ruby
Seaports.count          # => 17520
Seaports.all            # => [#<data Seaports::Port ...>, ...]
Seaports.data_release   # => "2024-2"
```

The table ships inside the gem as a CSV. It is reference data that changes
twice a year, and a port name should not depend on a network. Nothing is
fetched at runtime, and the file is parsed once, on the first lookup rather
than at require time.

Lookups are case- and whitespace-insensitive, and anything that is not shaped
like a locode — two letters and three alphanumerics — resolves to `nil` rather
than being guessed at. `nil` is also the answer for a code the table does not
hold: seventeen thousand ports is most of the world's, not all of it, so an
unknown code is the ordinary case rather than an error.

Roughly a third of the table has no position published. That is a fact about
the source, not a failure — the name is still worth having, and a map simply
draws no marker.

### What is deliberately not in it

Only entries UNECE marks with function `1`, "port", are kept. A road terminal,
an airport or a postal exchange sharing a city with a port must never answer a
lookup for a vessel's port call: `CNSHA` is Shanghai Hongqiao airport, and the
port of Shanghai is `CNSGH`.

The notable absence is `PAPCN`, "Panama Canal", which some feeds do send. UNECE
files it as a road terminal with status `RL` — "recognised location", its
weakest, meaning no national authority approved it and its functions were never
verified. That is the default bucket for an unchecked entry rather than a
ruling, but the substance holds anyway: a canal is a waterway, not a port. The
ports at either end are coded properly, `PABLB` Balboa and `PACTB` Cristóbal, so
a canal transit is better rendered from the country than from a port lookup.

Keeping the filter narrow also guards anyone rebuilding a five-character locode
from a three-character carrier code, which is a heuristic: a code that is not a
locode tail could pair with a country to form a valid-looking locode for some
inland village, and a table of ports is far less likely to name it.

## What it costs

A lookup is a hash fetch. The table is parsed once, on the first lookup rather
than at require time, and after that nothing touches the disk again.

| | |
| --- | --- |
| lookup | **0.31 µs** — about 3.2M per second |
| miss | 0.28 µs |
| malformed input | 0.25 µs — rejected on shape before the table is consulted |
| first lookup, which parses the table | ~140 ms, once per process |
| resident table | 3.9 MB |

Measured on Ruby 4.0, Apple Silicon, against the shipped 468 KB table. Reading
the file off disk is 0.4 ms of that first 140 ms; the rest is CSV parsing and
building the 17,520 objects, so it is CPU rather than I/O.

There is no database, no ActiveRecord, and no query per lookup. That is worth
saying because the alternative approach in this corner of the ecosystem is to
ship a SQLite file and read it through ActiveRecord, which puts a second
database connection and a version-pinned ORM into the dependency graph of an
application that only wanted to turn `CNXMG` into `Xiamen Pt`. A CSV and a hash
answer the same question with one dependency and no connection.

Nothing here is cached, because there is nothing left to cache: the table
already is the cache. A `Rails.cache` round trip costs around a millisecond,
which is some three thousand times slower than the lookup it would be caching.

The one cost worth managing is that first 140 ms, and the fix is to move it off
the request path rather than to cache it:

```ruby
# config/initializers/seaports.rb
Rails.application.config.after_initialize { Seaports.count }
```

## How the table stays current

UNECE republishes twice a year and does not announce it. A scheduled workflow
rebuilds the table weekly and, on the rare week something moved, opens a pull
request for a person to merge:

```
rake seaports:refresh          # fetch the current release, rebuild, report
rake seaports:refresh[path/to/code-list.csv,2025-1]
```

The source is the [datasets/un-locode][mirror] distribution, which republishes
UNECE's list with headers, UTF-8 and a machine-readable release number; UNECE's
own download is a zip of headerless latin-1 files.

That mirror is a third party, which is the whole reason the refresh does not
simply commit what it downloads. Seventeen thousand rows are not reviewable by
eye, so `Seaports::Diff` reads them instead, and refuses the rebuild outright
if:

- fewer than 15,000 ports survive, or the table shrank by more than 2% in one
  release — a truncated download rather than a busy half-year;
- any of sixteen anchor ports spread across the continents has vanished, which
  catches a source that dropped one region while keeping its row count healthy;
- `PAPCN` has been reclassified as a port upstream, which should be a decision
  someone makes rather than a row that appears quietly.

A refusal leaves the working tree exactly as it was and opens an issue. A pass
bumps the minor version, records the new UN/LOCODE release, writes the
changelog entry, and puts the whole diff in the pull request body — every
removal listed in full, because those are the changes that break a caller, and
position changes called out separately, because they move markers on a map.

Merging that pull request changes `lib/seaports/version.rb`, which is the only
thing that triggers a release. The gem is published by RubyGems trusted
publishing, so there is no API key in this repository.

## Versioning

Semver, where the data is the product:

| | |
| --- | --- |
| **patch** | code fixes, table unchanged |
| **minor** | a UN/LOCODE refresh — ports added, renamed, repositioned |
| **major** | an API change, or a refresh that removes ports known to be load-bearing |

`Seaports.data_release` tells you which UN/LOCODE edition your copy carries,
which is the question a gem version cannot answer.

## Licence

The code is MIT. The table is derived from the UN/LOCODE code list published by
UNECE, which is public domain, by way of the [datasets/un-locode][mirror]
distribution released under PDDL-1.0. See [LICENSE.txt](LICENSE.txt).

[mirror]: https://github.com/datasets/un-locode
