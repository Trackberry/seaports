# Changelog

Every entry below the first is a UN/LOCODE refresh, opened as a pull request by
`.github/workflows/refresh.yml` and merged by a person.

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
