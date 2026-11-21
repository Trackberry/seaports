# Changelog

Entries are written by `.github/workflows/refresh.yml` when it opens a refresh
pull request, or by hand for a code change; a person merges both.

## 1.6.0 — 2026-11-21

Ports now carry their other names. `Seaports.find("BEANR").alternate_names` is `["Antwerp", "Anvers"]`, where `name` is UN/LOCODE's `Antwerpen`; `Seaports.alternate_names(locode)` is the shortcut, and `[]` answers for a port with none. 698 of 17,567 ports have at least one.

The names come from three places, best first: a reviewed list, `data/sources/alternate_names.csv` (Genoa, Dunkirk, Bombay, Rangoon and 7 more the other sources lack); the [NGA World Port Index](https://msi.nga.mil/Publications/WPI)'s "Alternate Port Name" column, split on `;` and `,` (public domain, credited as NGA asks), skipping a locode that is not in the table or is on more than one index row, and filtering vessel, terminal, base, company and country names and fragments; and the name in the parentheses of UN/LOCODE's name (`El Iskandariya (Alexandria)`), for ports with a position, when it is one plain name. Spellings that differ only in case, accents or punctuation count as one, and a name equal to the port's own is dropped.

A main name always beats an alternate: a name that is another port's own name in the same country is dropped, and so is one that two or more ports of a country share (`Bruxelles` on three Belgian ports), so no alternate points at the wrong port. `data/sources/alternate_names_rejected.csv` lists wrong-place names a person has refused. The names are still not checked against the place, so a few are a bay or a point near the port.

The table has a new last column, `alternate_names`, separated by `|`. `Seaports::Port` has a new last member, `alternate_names`, defaulting to a shared empty list, so a Port built without it still works. Because it is a new member, `Port#to_h`, `Port.members` and `deconstruct`/`deconstruct_keys` gain a key, and a `Port` serialised with `Marshal` by 1.5.0 will not load in 1.6.0. `rake seaports:refresh_wpi` regenerates `data/sources/alternate_names_wpi.csv` with the coordinates, under the same checks, and refuses an index that lacks the "Alternate Port Name" column or loses more than 5% of the names already used. `rake seaports:apply_alternate_names` writes the name files into the table without a download. A change to the names alone is a change to the table: the refresh diff counts changed, added and removed names under "Names", they make a release, and the changelog entry mentions them.

Same ports, names and positions as 1.5.0.

## 1.5.0 — 2026-11-21

Fills in positions for 1,283 more ports from two open datasets, so 13,216 of 17,567 ports now have coordinates, up from 11,933. Where UN/LOCODE publishes no position and the reviewed list has none, the [NGA World Port Index](https://msi.nga.mil/Publications/WPI) (Pub. 150, snapshot 2026-09-29; public domain, credited as NGA asks) places 1,172 ports, Cork, Rosslare, Limerick, Foynes, Dover and Mombasa among them, and Wikidata (CC0, port and harbour items only) places 111 more. Ireland goes from 73 ports with a position to 86. UN/LOCODE's own position always wins, then the reviewed list, then the World Port Index, then Wikidata; a position more than 50 km outside its country is not used.

The new positions also place ports on the boundaries map, so 601 ports gain a subdivision (15,209 now, from 14,608).

The table has a new last column, `coordinate_source`: `unlocode`, `override`, `wpi` or `wikidata`, or empty for a port with no position. It records what the build knows, so a later step never has to infer from equal values whether UN/LOCODE published a position.

The refresh workflow now regenerates both sources every week, before the UN/LOCODE rebuild, so the rebuild's gates judge the coordinate changes with everything else, and refuses a rebuild that moves more than 5% of positions over a kilometre. The release is decided by the rebuilt table (a move under 100 m is not a change); a run that only changed the generated source files opens a pull request without a release. `rake seaports:refresh_wpi` fetches the newest World Port Index from NGA, or from the Internet Archive while NGA is in maintenance, validates it, and replaces the vendored copy in `data/sources/wpi/`, its provenance note and the generated coordinates together or not at all. `rake seaports:refresh_wikidata` queries Wikidata. Neither is shipped in the gem; only the table is.

Requires Ruby 3.3 or newer. Ruby 3.2 reached end of life on 2026-03-31 and is no longer tested.

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
