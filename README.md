# Seaports

[![CI](https://github.com/Trackberry/seaports/actions/workflows/ci.yml/badge.svg)](https://github.com/Trackberry/seaports/actions/workflows/ci.yml)
[![Gem](https://img.shields.io/gem/v/seaports)](https://rubygems.org/gems/seaports)

A locode in, a port name and a position out.

```ruby
Seaports.name("CNXMG")                   # => "Xiamen Pt"
Seaports.coordinates("AUBNE")            # => { "lat" => -27.4667, "lng" => 153.0167 }
Seaports.principal_subdivision("DEHAM")  # => "DE-HH"
Seaports.find("KRPUS")                   # => #<data Seaports::Port locode="KRPUS", name="Busan", ...>
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

Every entry UN/LOCODE classifies as a sea port: **17,527 ports**, 11,820 of them
with published coordinates and 14,567 with a subdivision, built from
**UN/LOCODE 2024-2**.

```ruby
Seaports.count          # => 17527
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

### Subdivisions

UN/LOCODE files each place under a subdivision of its country, which joined to
the country is an ISO 3166-2 code. It picks whatever level suits the country:
a state for Hamburg, a county for Felixstowe. Each port carries that code, the
**path** of every ISO subdivision above it, and the **principal subdivision**
at the top:

```ruby
Seaports.subdivision("GBFXT")            # => "GB-SFK"  Suffolk
Seaports.principal_subdivision("GBFXT")  # => "GB-ENG"  England
Seaports.subdivision_path("FRSXB")       # => ["FR-67", "FR-6AE", "FR-GES"]  Bas-Rhin › Alsace › Grand Est
Seaports.principal_subdivision("DEHAM")  # => "DE-HH"   Hamburg, already top level
Seaports.principal_subdivision("ESVLC")  # => "ES-VC"   Comunitat Valenciana
```

To join a port to other data, a public holiday calendar say, match on
whichever level of the path that data uses. The principal subdivision is
usually the one (German states, UK nations, Spanish communities), but ISO's
top level is not always where things are decided: Alsace-Moselle (`FR-6AE`)
keeps holidays the rest of Grand Est does not, Ireland's top level is its four
provinces rather than its counties, and Indonesia's is island groups (`ID-JW`
Java) rather than provinces (`ID-JK` Jakarta). The path carries every level, so
matching on any of it is always safe.

A port's subdivision comes from the first of three sources that has one, and
the table records which (`subdivision_source`):

| Source | Ports | How |
| --- | --- | --- |
| `override` | 106 | A reviewed list, `data/sources/subdivision_overrides.csv`, for ports neither of the others places: Valencia, Algeciras and Barcelona have no subdivision and no position in UN/LOCODE. Each row says where its code came from. |
| `unlocode` | 13,149 | UN/LOCODE's own subdivision column. |
| `boundaries` | 1,312 | The port's coordinates placed on [Natural Earth](https://www.naturalearthdata.com/)'s states-and-provinces map (public domain, pinned to one commit), or the nearest subdivision within 10 km when a waterfront position lands just offshore. Amsterdam is placed this way. |

Every code is checked against ISO 3166-2, and the path follows ISO's own
hierarchy, taken from
[Debian's iso-codes](https://salsa.debian.org/iso-codes-team/iso-codes). A code
whose chain is broken in that list is dropped rather than shipped without a
trustworthy top. Both maps are read when the table is built; nothing is
fetched at runtime.

2,960 ports stay without one, mostly offshore fields and moorings, and ports in
countries with no regional distinctions worth drawing. To place more, run
`ruby script/suggest_subdivision_overrides.rb candidates.csv`: it searches each
port's name on OpenStreetMap's Nominatim and prints suggestions with the place
it matched, for a person to check before adding them to the overrides file. A
name search does find the wrong Puerto de Santa María. Place names in the
overrides file are © OpenStreetMap contributors, under the
[ODbL](https://www.openstreetmap.org/copyright).

Each refresh lists, for review, overrides that have outlived their reason: a
port that left UN/LOCODE, or one UN/LOCODE now places itself.

`Seaports::Port` gained `subdivision`, `principal_subdivision` and
`subdivision_path` in 1.2.0, all optional, so a `Port` built from locode, name
and coordinates as before still works.

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
