# Changelog

Every entry below the first is a UN/LOCODE refresh, opened as a pull request by
`.github/workflows/refresh.yml` and merged by a person.

## 1.2.0 — 2026-10-20

Each port now carries its ISO 3166-2 subdivision and the principal (top-level) subdivision above it: `Seaports.subdivision("GBFXT")` is `"GB-SFK"` (Suffolk), `Seaports.principal_subdivision("GBFXT")` is `"GB-ENG"`. The principal one is the level public holiday calendars and address geocoders use, so a port can be joined to them. 14,569 of 17,527 ports have one: 13,149 from UN/LOCODE's subdivision column, 1,312 placed by their coordinates on Natural Earth's states-and-provinces map (Amsterdam), and 108 from a reviewed list for ports with neither (Valencia, Algeciras, Barcelona). Every code is checked against ISO 3166-2 (Debian iso-codes) at build time. Same UN/LOCODE 2024-2 ports, names and positions as 1.1.0.

## 1.1.0 — 2026-10-19

UN/LOCODE release unknown. 17527 sea ports (17520 before): 7 added, 0 removed, 1 renamed, 83 repositioned.

## 1.0.0 — 2026-08-21

First release. Extracted from the Trackberry application, where this table
answered port calls from AIS tracking feeds. Built from UN/LOCODE 2024-2:
17,520 sea ports, 11,762 of them with published coordinates.
