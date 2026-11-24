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

Every entry UN/LOCODE classifies as a sea port: **17,567 ports**, 13,216 of them
with coordinates and 15,209 with a subdivision, rebuilt from UNECE's
latest published list whenever it changes.

```ruby
Seaports.count              # => 17567
Seaports.all                # => [#<data Seaports::Port ...>, ...]
Seaports.data_refreshed_on  # => #<Date: 2026-11-02>
Seaports.data_release       # => nil, or "2024-2" when the source names an edition
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

About a quarter of the table has no position at all, and about a third has none published by UN/LOCODE. That is a fact about
the source, not a failure: UN/LOCODE's coordinates column is optional, and each
country's national focal point decides whether to fill it when it registers or
updates a location. Many old entries were never given one, among them some of
the busiest ports in Spain. The name is still worth having, and a map simply
draws no marker. For the ports that matter most to a map or an arrival check,
a [reviewed list](#coordinates) fills the gap.

### Coordinates

A port's position comes from UN/LOCODE where it publishes one, which is
degrees and whole minutes, so about a mile. For the ports it leaves blank, three
other sources fill the gap, in this order, and the first that has a position
wins:

1. **A reviewed list**, `data/sources/coordinate_overrides.csv`: the position of
   the **port area**, the harbour or terminals rather than the city centre, to at
   most four decimal places, most to about a kilometre. Valencia, Algeciras,
   Barcelona and Gibraltar have no position in UN/LOCODE, and are filled this
   way, with 62 other ports of the busiest produce and container trades.
2. **The NGA World Port Index** (Pub. 150), `data/sources/coordinates_wpi.csv`:
   about 3,800 ports with a UN/LOCODE and a position. It fills 1,172 ports,
   Cork, Rosslare, Limerick, Foynes, Dover and Mombasa among them.
3. **Wikidata**, `data/sources/coordinates_wikidata.csv`: items carrying a
   UN/LOCODE (P1937) and coordinates (P625). Only items typed as a port or
   harbour are used, because a town item is a city centre and often inland, so
   it fills just 111 ports the first two leave. A code that is also on a town
   item needs its port item within 50 km of it, and several port items need to
   lie within 10 km of each other, or the code is skipped.

Each generated row names its `source`: the World Port Index edition, or the
Wikidata item and its kind (`Wikidata Q123 (port, CC0)`). The table records
the source of every position in its `coordinate_source` column (`unlocode`,
`override`, `wpi` or `wikidata`), written by the build, so what UN/LOCODE
published is never guessed from equal values. A supplementary position only ever fills a gap. If UN/LOCODE
publishes a position for the port, that one ships, and the row drops out of
the generated file the next time it is regenerated, so the source of record
stays in charge and a stale row cannot mask better data. For the reviewed list
the refresh reports the row instead, and CI holds the refresh pull request until
it is removed. A position outside its own country, by more than 50 km on
Natural Earth's map, is not used, nor is a UN/LOCODE that two World Port Index
ports share (Wikidata may still fill such a code). A territory the map does not
draw as a country (Aruba, Guam, the Falklands) cannot be checked against its
parent state and is kept unchecked; the refresh summary counts those.

**Licences and attribution.** The World Port Index is published by the US
National Geospatial-Intelligence Agency, a work of the US government in the
public domain; the gem credits it as a courtesy, which NGA asks for.
Wikidata's data is [CC0](https://creativecommons.org/publicdomain/zero/1.0/), and
the reviewed list's placements were checked against
[OpenStreetMap](https://www.openstreetmap.org/copyright) data, © OpenStreetMap
contributors, ODbL.

`rake seaports:refresh_wpi` looks for a newer World Port Index: NGA first, and
when NGA answers with its maintenance page, as it often does, the Internet
Archive's newest snapshot of the same URL. A download is used only when it has
the expected columns, a row count within 5% of the vendored copy, a last row as long as the header
(not cut off) and Cork in it. If its content (its sha256, ignoring line endings and a byte order mark)
differs from the vendored copy in `data/sources/wpi/`, the copy, its
`provenance.json` (where it came from, the snapshot date and the hash) and the
regenerated `coordinates_wpi.csv` are replaced together, or none of them is; if
not, nothing happens. A download older than the vendored snapshot is refused, so two editions seen
by turns cannot flip the file. A regeneration that loses more than 2% of the World Port
Index rows already used (rows that left because UN/LOCODE, the reviewed list or the
table now holds the port do not count), or that moves more than 5% of a file's positions over a
kilometre, is refused. Given a path and a snapshot date,
`rake "seaports:refresh_wpi[/path/UpdatedPub150.csv,2026-09-29]"` uses a file
already downloaded. `rake seaports:refresh_wikidata` rebuilds the Wikidata file
from a live query, and refuses an answer with fewer than 80% of the codes it
expects or one that loses over 10% of the rows it replaces. Neither task touches the table: `rake seaports:refresh` runs after
them and merges what they wrote, so its gates judge the coordinate changes too.
The weekly refresh workflow runs all three in that order, and an unreachable
source is a warning, not a failure; a source that answers with something its
gates refuse also opens an issue. Both send a generic `User-Agent` naming the gem and its
repository.

The reviewed list's rows were placed by hand, to roughly a kilometre, then each
was checked by reverse geocoding it on
[OpenStreetMap](https://www.openstreetmap.org/copyright): the positions are
checked, and three corrected, against OpenStreetMap data, © OpenStreetMap
contributors, ODbL. The point must land in the port's own town, on or by its
harbour. Three did not, and were moved:

- **Salerno** (`ITSAL`) was about a kilometre out in the gulf, at sea: now on
  the harbour front.
- **Santander** (`ESSDR`) was across the bay, at Pedreña: now at the Raos
  cargo terminals.
- **Avilés** (`ESAVS`) was across the ría, in Castrillón: now in the port area.

A point a kilometre off is harmless on a world map, but not for a check that
asks whether a ship is at the port, which is why the check is part of adding a
row. It is not a survey of berths: a row is only as precise as its note says.
The World Port Index and Wikidata positions are less checked than the reviewed
ones, often a town centre or a harbour mouth rather than a berth, so treat
them as "in the right place" and not as "at the quay". About 4,350 ports,
mostly small ones, still have no position.

`rake seaports:refresh` merges all three into the rebuilt table, and the
position also places the port on the boundaries map for its subdivision.
Between refreshes, `rake seaports:apply_coordinates` writes the files' rows
into the shipped table without a download (it fills ports with no position, and
does not place them on the map, so a port placed between refreshes has no
subdivision until then).

### Alternate names

UN/LOCODE names a port the way its country does, so BEANR is `Antwerpen` and a
document that says `Antwerp` finds nothing. `alternate_names` lists the other
names:

```ruby
Seaports.find("BEANR").alternate_names  # => ["Antwerp", "Anvers"]
Seaports.alternate_names("BEANR")       # => ["Antwerp", "Anvers"]
Seaports.alternate_names("NLRTM")       # => []
```

Never the port's own `name`, and `[]` when there are none. 659 ports have at
least one. Sources, best first:

1. **A reviewed list**, `data/sources/alternate_names.csv` (`locode`, `name`,
   `source`): English names and former names the other two lack, such as Genoa,
   Dunkirk, Bombay and Rangoon.
2. **The NGA World Port Index** (Pub. 150), `data/sources/alternate_names_wpi.csv`:
   its "Alternate Port Name" column, split on `;` and `,`. Generated by
   `rake seaports:refresh_wpi` with the coordinates; do not edit it. Rows for a
   locode that is not in the table, or that is on more than one index row, are
   skipped, the same as for coordinates. Names that are not places are
   filtered: vessels (`FSO`, `FPSO`, `MV`), terminals, bases, oil and naval
   names, companies (`AS`), country names and fragments under four characters.
3. **The parenthesized name** in the UN/LOCODE name, `El Iskandariya
   (Alexandria)` giving `Alexandria`, only for a port with a position, and only
   when the parenthesis is one name of at least four characters: not a list
   (`/` or a comma), a former name (`Mumbai (ex Bombay)`), a facility or a zone.

None of these sources is checked against the place, so an alternate is a name
the port is called by in some source, not a guarantee. What keeps it honest:

- **A main name always beats an alternate.** A name that is another port's own
  name in the same country is dropped, and so is a name that two or more ports
  of a country share as alternates (`Bruxelles` is on three Belgian ports). A
  name that fits several ports names none of them.
- `data/sources/alternate_names_rejected.csv` (`locode`, `name`, `reason`) lists
  names a person has reviewed and refused, whichever source offers them: a
  neighbouring city, a state, an island. Add a row when you find one.

Spellings that differ only in case, accents or punctuation count as one, and
any that equals the port's name is dropped. Some remaining names are still
places near the port (a bay, a point, a harbour) rather than the port itself,
and typos in the index are kept as written. The table keeps them in its last
column, `alternate_names`, separated by `|`. After adding rows to either list,
`rake seaports:apply_alternate_names` writes them into the table without a
download; the next refresh rebuilds the same names.

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
top level is not always where things are decided: Alsace (`FR-6AE`) and
Moselle (`FR-57`) keep two holidays the rest of Grand Est does not, and sit at
different levels, since ISO has no Alsace-Moselle code (Metz's path is
`["FR-57", "FR-GES"]`). Ireland's top level is its four
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
port that left UN/LOCODE, or one UN/LOCODE now places itself. That goes for
coordinate overrides too: a port that left, or one UN/LOCODE now gives a
position.

`Seaports::Port` gained `subdivision`, `principal_subdivision` and
`subdivision_path` in 1.2.0, all optional, so a `Port` built from locode, name
and coordinates as before still works. 1.6.0 added `alternate_names` the same
way, optional and defaulting to a shared empty list. Because it is a new member,
`Port#to_h`, `Port.members` and `deconstruct`/`deconstruct_keys` gain a key, and
a `Port` serialised with `Marshal` by 1.5.0 will not load in 1.6.0.

### Port outlines

A point says where a port is; an outline says whether a ship is in it. Sevilla
and Huelva sit up their rivers, Rotterdam's Maasvlakte is 30 km from the city
UN/LOCODE places it on, and Antwerp's ships wait at anchor off Vlissingen,
60 km downriver. A radius around one point gets all of those wrong.

For a few ports the gem ships an outline: the port limits, the anchorages, the
terminals with their operator and cargo type, and the pilot boarding places.

```ruby
Seaports.geometry_locodes                        # => ["BEANR", "GBDVR", "NLRTM"]
Seaports.within?("NLRTM", 51.955, 4.03)          # => true, on the Maasvlakte
Seaports.within?("NLRTM", 51.955, 4.03, kind: :anchorage)  # => false
Seaports.areas_at("NLRTM", 51.977, 4.033).map(&:name)
# => ["Euromax Terminal", nil]   the terminal, then the port limits
Seaports.terminals("NLRTM").first.cargo          # => ["container"]
Seaports.anchorages("BEANR").map(&:name)         # => ["Rede van Antwerpen", ...]
Seaports.quays("NLRTM")                          # => ["NLAWD", "NLBOT", ...]
Seaports.ports_at(51.0, 1.5)                     # => [], mid-Channel
Seaports.geometry("GBDVR")                       # => the GeoJSON FeatureCollection, for a map
```

Each area is a `Seaports::Geometry::Area` with `kind` (`port_limits`,
`anchorage`, `terminal` or `pilot_boarding`), `name`, `operator`, `cargo` (from
`container`, `reefer`, `ro_ro`, `bulk`, `tanker`, `general`, `passenger`),
`category` for an anchorage, its GeoJSON `geometry`, a label point (`lat`,
`lng`) inside it (a test holds every shipped area to that), and where it came from: `osm` (the
OpenStreetMap ids), `source`, `licence`, `reviewed_at` and a `note`. `quays`
are the other locodes that are really parts of the port (`NLBOT` Botlek for
Rotterdam), so a feed that names one is talking about this port. A port with no
outline answers `nil`, `[]` and `false`, which says nothing about where a ship
is: ask `geometry` first when that matters.

**No coordinate here was typed or generated.** Every shape is an OpenStreetMap
feature, chosen by its id in a reviewed selection,
`data/geometry/sources/<LOCODE>.yml`, and fetched from OpenStreetMap by
`rake seaports:geometry`. The selection says which features are the port's,
what each is called and what cargo it takes, and holds no coordinates, so a
person, an agent or a reader's correction can only choose among shapes
OpenStreetMap already has. A part of a port that OpenStreetMap does not map is
mapped there first.

OpenStreetMap maps port limits for none of the three ports so far, so their
limits are derived: the convex hull of the port's terminals (and any docks the
selection names) grown by a stated distance, with `source` saying so. That is
rougher than the legal limits and takes in land between the quays, which is
what a "is this ship in the port?" question needs and no more.

A hull cannot follow a concave harbour, though: it takes in the town on the
hill behind Lyttelton, Mount Maunganui between Tauranga's two wharves, and
Petit-Couronne between Rouen's quays. No ship is ever there, and the drawing
and the notes say a town is "in the port". With `clip: water`, the hull is
cut down to the water OpenStreetMap maps inside it, and the terminals are
kept whole:

```yaml
port_limits:
  derive: hull
  buffer_m: 300
  clip: water
  # disjoint: why the limits are in parts, when the water does not join them
  note: ...
```

The limits become the hull ∩ (sea ∪ mapped water ∪ the terminals, and any
areas the selection lists under `osm:`, ∪ the part of those grown by 30 m that
lies within 30 m of the water). The 30 m only bridges between a terminal and
the water (listed basins count as water here), so a quay drawn a few metres
back from the mapped coastline still joins it. Land is taken only where it is
within 30 m of both, which is the gap to the water, about 30 m of shore either
side of a terminal's ends, and, behind a terminal narrower than 30 m, the
strip still within 30 m of the water. Behind the fence of a deeper terminal,
housing stays outside the limits. The terminals themselves are always kept
whole (padded by 1 m once simplified, so rounding cannot nick them). The sea is the
side of OpenStreetMap's coastline (`natural=coastline`, drawn with the land on
its left) that the coastline says it is; the mapped water is
`natural=water` (rivers, docks, basins, lakes), `waterway=riverbank` and
`waterway=dock`, and canals drawn as areas. `landuse=harbour` is left out,
since it often maps the whole port, quays and sheds included. Water that
touches no terminal (a pond in a park) is dropped, holes under a hectare are
filled, and the outline is simplified to within 8 m. The result can be a
MultiPolygon; `Area#contains?` and `Seaports.within?` answer for any part. It
is fetched from the same place as the shapes (Overpass, or the Geofabrik
extract with `OSM_SOURCE=extract`), so no coordinate is typed here either.

Two more checks apply to clipped limits. The build refuses a terminal with no
water within 30 m of it inside the hull, since a ship alongside it would fall
outside the limits; that is usually a river or a dock OpenStreetMap maps only
as a line. And the limits must be one body of water unless the selection says
why not with `disjoint`: a part on its own is usually a terminal whose water
is not mapped as an area, or one that is not on the water at all.

Clipping is build-time work for [GEOS](https://libgeos.org), through the
[rgeo](https://github.com/rgeo/rgeo) gem's C extension, in the Gemfile, not
the gemspec: `brew install geos` or `apt-get install libgeos-dev` before
building a port that uses it: rgeo installs without GEOS when the library is
missing at install time, so the build stops with a clear message unless
`RGeo::Geos.capi_supported?`, and CI checks it. Robust overlay of concave polygons with holes is
GEOS's work and not something to hand-roll. The outlines it builds are shipped
as plain GeoJSON, so the gem itself still depends on nothing but `csv`, and a
port without `clip: water` never loads it. GEOS releases can simplify the same
shape a vertex differently, so the build log names the GEOS version, and a
clipped port rebuilt on a laptop and then by the weekly run may move by a
vertex with no change in OpenStreetMap.

A port that adopts `clip: water` will often find UN/LOCODE's position, the
city centre, outside its limits once the land is gone: give the reason in
`position_outside`, as for Rotterdam.

How a port is drafted:

1. `rake "seaports:geometry_candidates[NLRTM]"` lists the OpenStreetMap
   features near the port that could be part of it (harbours, docks, terminals,
   anchorages, berths, pilot boarding places), by id and tags, without their
   shapes, and drops the marinas. Give it a radius, and a position for
   anchorages far out: `[BEANR,22,51.42,3.45]`.
2. A person, or an agent, writes the selection from that list: which features
   are terminals and anchorages, their names, operators and cargo, the
   neighbouring locodes that are quays, and a note on each choice.
3. `rake "seaports:geometry[NLRTM]"` fetches the shapes and runs the checks,
   and writes `data/geometry/NLRTM.geojson` only if they pass. The checks:
   valid closed rings that do not cross themselves, one set of port limits that
   contains the port's own position (or a reviewed `position_outside` reason
   why not: Rotterdam's position is its city centre), plausible sizes, a
   source, licence and review date on every feature, quays that are real
   locodes, and no terminal inside another port's limits. Gaps are warnings:
   no anchorage mapped, a terminal with no cargo type, an anchorage with no
   category, and limits that overlap another port's (shape against shape, not
   their bounding boxes).
   `rake seaports:geometry` asks the public Overpass API by default. With
   `OSM_SOURCE=extract` it reads OpenStreetMap from
   [Geofabrik's](https://download.geofabrik.de) daily extracts instead, on
   this machine with [osmium-tool](https://osmcode.org/osmium-tool/)
   (`brew install osmium-tool`, `apt-get install osmium-tool`): nothing to
   rate-limit it, and the same answer from the same day's data. Each feature
   is read from the smallest regions that hold its shipped shape
   (`europe/netherlands/zuid-holland` for most of Rotterdam, Belgium and
   Zeeland for an anchorage on the Scheldt), downloaded once into `tmp/osm`,
   checked against Geofabrik's MD5 and reused for three days
   (`OSM_EXTRACT_MAX_AGE_DAYS`). The build log names each region and the
   date its data is from. A new port has no shape to choose by, so it is
   looked for around its UN/LOCODE position; when a feature lies beyond that,
   name the region: `OSM_REGION=europe/netherlands`. A continent is never
   downloaded unless named that way. It is the same OpenStreetMap data
   under the same licence, and gives the same GeoJSON as Overpass does for
   the same data.
4. Each port is a pull request. On one that edits a selection,
   `.github/workflows/geometry.yml` builds the outline and commits it to the
   branch, so the reviewer sees shapes. Weekly, it rebuilds every port to pick
   up OpenStreetMap's edits, from Geofabrik's extracts, and opens one pull
   request with what moved. The GeoJSON has one feature per line, so that
   diff shows which terminal moved.

Not checked yet: that anchorages are on water and terminals touch land, and
that outlines match where ships really stop. Both wait for a record of ship
stops by type.

The outlines are © OpenStreetMap contributors and published under the
[Open Database Licence](https://opendatacommons.org/licenses/odbl/1-0/),
separately from the gem's MIT code: see
[data/geometry/LICENSE.md](data/geometry/LICENSE.md). Credit OpenStreetMap
wherever you draw them; the collection's `attribution` member is the line to
use.

### Canal outlines

A canal is not a port, and its queue is not port congestion. Ships anchored off
Port Said in the C and V areas are waiting for a Suez convoy, not for a berth
at Port Said; ships in the Great Bitter Lake are part-way through, waiting for
the convoy coming the other way to pass. The gem ships outlines for the Suez,
Panama and Kiel canals and the Turkish Straits so a tracker can say "waiting to transit Suez since
Tuesday" rather than "at anchor, Port Said".

```ruby
Seaports.canal_ids                               # => ["kiel", "panama", "suez", "turkish_straits"]
suez = Seaports.canal("suez")
suez.anchorages.size                             # => 78
suez.anchorages_for(:north).map(&:name).first(3) # => ["C1", "C2", "C3"]
suez.end_name("north")                           # => "Port Said"
area = Seaports.canal_anchorage_at(31.3585, 32.3350)
[area.canal, area.name, area.approach]           # => ["suez", "C1", "north"]
Seaports.canal_anchorage_at(51.0, 1.5)           # => nil, mid-Channel
suez.waterway.geometry["type"]                   # => "MultiLineString"
Seaports.canal("panama").collection              # => the GeoJSON FeatureCollection, for a map
Seaports.canal("kiel").end_name(:west)           # => "Brunsbüttel"
```

Each canal is a `Seaports::Canal` with an `id`, a `name`, its two `ends` and
its areas, each a `Seaports::Canal::Area`. The ends are named for the way the
canal runs: `north` and `south` for Suez (Port Said and Suez) and Panama (Colón
on the Atlantic and Balboa on the Pacific), `west` and `east` for the Kiel
Canal (Brunsbüttel on the Elbe and Kiel-Holtenau on the Kiel Fjord), and
`north` and `south` for the Turkish Straits (Istanbul on the Black Sea and
Çanakkale on the Aegean).
`approaches` lists the canal's two ends and `in_transit`. The areas:

- one `waterway`, the canal's centreline as OpenStreetMap maps it. It is a
  line, not an area: OpenStreetMap maps most of the Suez Canal's water as sea
  behind the coastline, and Panama's as Gatún Lake, Miraflores Lake and the locks
  separately, so neither has one water area for the whole canal. Use it to
  draw the canal, not to ask whether a ship is in it;
- the `anchorage`s where ships wait, each with an `approach`: one of the
  canal's ends for the end it serves, `in_transit` for a lake inside the
  canal (the Great Bitter Lake, Lake Timsah, Panama's Miraflores Lake);
- `pilot_boarding` places, with an `approach` too.

`canal_anchorage_at(lat, lng)` answers the waiting area a position is in,
whichever canal it belongs to, or nil.

The same rule as the port outlines: every shape is an OpenStreetMap feature
chosen by id, in `data/geometry/canals/sources/<id>.yml`, and built into
`data/geometry/canals/<id>.geojson` by `rake "seaports:geometry[suez]"` (with
no argument, `rake seaports:geometry` builds every port and then every canal).
A canal has no UN/LOCODE position to choose a Geofabrik region by, so the first
build of a new one from extracts names it: `OSM_SOURCE=extract
OSM_REGION=africa/egypt`. `rake seaports:check_geometry` checks the canals with
the ports: shapes, sources and licence, the selection's digest and canonical
form (`Seaports::Canal::Builder.dump_selection`), a name and an approach on
every anchorage, no two overlapping anchorages serving different ends, and two
errors that are the point of the outlines: a canal anchorage that overlaps any
port's limits or anchorages, and an OpenStreetMap feature that is in both a
canal's outline and a port's. Building a port runs the same check the other
way.

What OpenStreetMap does not map is not here: anchorage B in Limon Bay, any
anchorage outside the Colón breakwaters, a pilot boarding place at the Suez
end, and anchorages off Port Said East. In Suez Bay only the northbound
convoy's waiting areas are the canal's: the V berths and the East Waiting Area,
which the Suez Canal Authority's Rules of Navigation give to incoming ships.
The West Waiting Area (W1 to W14), for ships awaiting orders, bunkering or
bound for Suez and Adabiya, and the lettered areas nearer Port Tawfiq are left
out, so a ship there reads as waiting for no canal.

At the Kiel Canal only the two roadsteads the Bekanntmachung zur
Seeschifffahrtsstraßen-Ordnung keeps for ships bound for the locks are the
canal's: the Nordwest-Reede off Brunsbüttel, for ships due to lock into the
next free lock, and the Holtenau-Reede in the Kiel Fjord, which OpenStreetMap
leaves unnamed. The Holtenau-Reede also takes ships waiting for a berth in the
port of Kiel or for better weather, so a ship there reads as waiting at the
east end whichever it is waiting for. The Elbe's other roadsteads near Brunsbüttel (the Südreede, the
Nordostreede off the Elbehafen, the Neufeld roadsteads) serve the river, not
the canal. OpenStreetMap draws the Nordwest-Reede as an open line along the
fairway, so its area is that line grown by 300 m. It maps no sidings inside
the canal as areas, and no pilot boarding place at Brunsbüttel.

The Turkish Straits (`turkish_straits`) are a waterway only, with no waiting
areas yet. OpenStreetMap maps the Bosporus and the Dardanelles as strait areas
bounded by the coastline (relations 8926171 and 8926172) and no waterway through
them, so the waterway is the traffic separation schemes' seamarks: the Istanbul
Strait's separation line, end to end, and the Çanakkale Strait's separation
zone, which OpenStreetMap maps only from off Gelibolu to off Çoraklık Burnu.
The narrows at Çanakkale, the stretch down to the Aegean and the Sea of Marmara
have no line. OpenStreetMap maps none of the anchorages the Turkish Straits
Maritime Traffic Regulation (2019) sets at the straits' entrances, and no pilot
boarding place. The only seamark anchorages there are the two inspection areas
of the Black Sea Grain Initiative, which ended in July 2023, and they are left
out.

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
UNECE's list with headers and UTF-8; UNECE's own download is a zip of headerless
latin-1 files. The mirror builds from UNECE's latest pre-release file, which has
no edition number, so a table can be newer than any named release.

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
bumps the minor version, records the refresh date and any UN/LOCODE edition the
source names, writes the changelog entry, and puts the whole diff in the pull
request body — every
removal listed in full, because those are the changes that break a caller, and
position changes called out separately, because they move markers on a map.

The same weekly run first refreshes the World Port Index and Wikidata
coordinates (see [Coordinates](#coordinates)), then rebuilds. The release is
decided by the rebuilt table: if a port's position or subdivision changed (a
move under 100 m does not count), the run bumps the minor version and writes a
changelog entry. If only the generated source files changed, with the same
positions, it opens a pull request to review and releases nothing. A rebuild
that moves more than 5% of the positions over a kilometre, or in which more than
2% of the positioned ports lose their position, is refused. The summary
says how many ports each source added, removed and moved, which World Port
Index snapshot it used, and lists the ports whose World Port Index name differs
from UN/LOCODE's.

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

`Seaports.data_refreshed_on` tells you the day your copy's table last changed,
which is the question a gem version cannot answer. `Seaports.data_release` names
the UN/LOCODE edition when the source gave one, and is nil otherwise.

## Licence

The code is MIT. The table is derived from the UN/LOCODE code list published by
UNECE, which is public domain, by way of the [datasets/un-locode][mirror]
distribution released under PDDL-1.0. See [LICENSE.txt](LICENSE.txt).

The port outlines in `data/geometry` are not: they are derived from
OpenStreetMap and published under the ODbL 1.0, © OpenStreetMap contributors.
See [data/geometry/LICENSE.md](data/geometry/LICENSE.md).

[mirror]: https://github.com/datasets/un-locode
