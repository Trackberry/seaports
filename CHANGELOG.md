# Changelog

Every entry below the first is a UN/LOCODE refresh, opened as a pull request by
`.github/workflows/refresh.yml` and merged by a person.

## Unreleased

Requires Ruby 3.3 or newer. Ruby 3.2 reached end of life on 2026-03-31 and is no longer tested.

## 1.5.0 — 2026-11-21

Fills in positions for 2,442 more ports from two open datasets, so 14,375 of 17,567 ports now have coordinates, up from 11,933. Where UN/LOCODE publishes no position and the reviewed list has none, the [NGA World Port Index](https://msi.nga.mil/Publications/WPI) (Pub. 150, snapshot 2026-09-29; public domain, credited as NGA asks) places 1,172 ports, Cork, Rosslare, Limerick, Foynes, Dover and Mombasa among them, and Wikidata (CC0) places 1,270 more. Ireland goes from 73 ports with a position to 90. UN/LOCODE's own position always wins, then the reviewed list, then the World Port Index, then Wikidata; a position more than 50 km outside its country is not used.

The new positions also place ports on the boundaries map, so 952 ports gain a subdivision (15,560 now, from 14,608).

The refresh workflow now regenerates both sources every week and opens one pull request for whatever moved, UN/LOCODE or coordinates. `rake seaports:refresh_wpi` fetches the newest World Port Index from NGA, or from the Internet Archive while NGA is in maintenance, validates it, and replaces the vendored copy in `data/sources/wpi/` when its content differs. `rake seaports:refresh_wikidata` queries Wikidata. Neither is shipped in the gem; only the table is.

Same ports and names as 1.4.0. Positions of ports that had one are unchanged.

## 1.4.0 — 2026-11-20

Fills in positions for ports UN/LOCODE publishes none for. A reviewed list, `data/sources/coordinate_overrides.csv`, places 66 ports by their harbour or terminals, among them Valencia, Algeciras, Barcelona, Gibraltar, Felixstowe, Southampton, Dublin, Savannah and Vancouver, so `Seaports.coordinates` answers for them instead of `nil`. A position only fills a gap: one UN/LOCODE publishes always wins, and the refresh reports an override that UN/LOCODE has since made redundant.

The rows are placed by hand to about a kilometre; each says how sure it is. Every one was checked by reverse geocoding on OpenStreetMap (© OpenStreetMap contributors, ODbL), and three were moved: Salerno sat at sea, Santander across the bay, Avilés across the ría. Adds `rake seaports:apply_coordinates` to write new rows into the shipped table without a download.

`Seaports.subdivision` stays nil for the 25 or so of these ports UN/LOCODE gives no subdivision (Jebel Ali, Gibraltar, Dublin, Montevideo, Buenaventura, Gdańsk, Tema…) until the next refresh, which places them on the boundaries map from their new positions. The README's counts are brought up to the table: 17,567 ports, 11,933 located, 14,608 with a subdivision.

Same ports and names as 1.3.1.

## 1.3.1 — 2026-11-08

`Seaports.data_release` no longer claims an edition the table did not come from. The mirror stopped publishing a release number, so refreshes kept the old "2024-2" label on newer data. It is now nil when the source names no edition, and a refresh clears it rather than leaving the previous value.

Adds `Seaports.data_refreshed_on`, the Date a refresh last changed the table. Use it instead of `data_release` to check how old the data is, and handle nil if you call `data_release`.

Same ports, names and positions as 1.3.0.

## 1.3.0 — 2026-11-02

UN/LOCODE release unknown. 17567 sea ports (17527 before): 46 added, 6 removed, 9 renamed, 22 repositioned, 2 with a new subdivision (0 moved to another principal one).

Removed: BRORX, FRG8V, FRHSN, JPNTO, JPRYA, MYTKP.

## 1.2.0 — 2026-10-20

Each port now carries its ISO 3166-2 subdivision, the path of every subdivision above it, and the principal (top-level) one: `Seaports.subdivision("GBFXT")` is `"GB-SFK"` (Suffolk), `Seaports.subdivision_path("FRSXB")` is `["FR-67", "FR-6AE", "FR-GES"]`, `Seaports.principal_subdivision("GBFXT")` is `"GB-ENG"`. Match on whichever level of the path other data uses: the principal one usually, but not for Alsace (`FR-6AE`) and Moselle (`FR-57`), Irish counties or Indonesian provinces.

14,567 of 17,527 ports have one: 13,149 from UN/LOCODE's subdivision column, 1,312 placed by their coordinates on Natural Earth's states-and-provinces map (Amsterdam), and 106 from a reviewed list for ports neither places (Valencia, Algeciras, Barcelona). Every code is checked against ISO 3166-2 (Debian iso-codes) at build time.

`Seaports::Port` gains three members, all optional, so `Port.new(locode:, name:, coordinates:)` still works. A positional pattern match on a three-element Port (`in [locode, name, coordinates]`) no longer matches; match by key instead.

Refreshes now ship a change at any level of a port's path, refuse a rebuild that moves more than 2% of ports to another principal subdivision, report overrides that have outlived their reason, and turn a failed download into a refusal issue rather than a failed build.

Same UN/LOCODE 2024-2 ports, names and positions as 1.1.0.

## 1.1.0 — 2026-10-19

UN/LOCODE release unknown. 17527 sea ports (17520 before): 7 added, 0 removed, 1 renamed, 83 repositioned.

## 1.0.0 — 2026-08-21

First release. Extracted from the Trackberry application, where this table
answered port calls from AIS tracking feeds. Built from UN/LOCODE 2024-2:
17,520 sea ports, 11,762 of them with published coordinates.
