# Build inputs

Files here feed `rake seaports:refresh` and are not shipped in the gem; only the table they help build is.

## subdivision_overrides.csv

Reviewed ISO 3166-2 subdivisions for ports that neither UN/LOCODE nor Natural Earth's map places, such as Valencia, Algeciras and Barcelona, which have no subdivision and no position in UN/LOCODE. An override wins over every other source, so a row should be removed once UN/LOCODE publishes a subdivision of its own; each refresh lists the rows that have reached that point.

The rows were suggested by `script/suggest_subdivision_overrides.rb` and checked by a person. The `note` column quotes the place each search matched, or explains a manual correction.

Those place names come from [OpenStreetMap](https://www.openstreetmap.org/copyright) through its Nominatim search: © OpenStreetMap contributors, available under the Open Database Licence (ODbL).

## coordinate_overrides.csv

Reviewed positions for ports UN/LOCODE publishes no coordinates for: the port area (harbour or terminals), not the city centre, to four decimals. Columns: `locode`, `name` (for review, ignored by the build), `lat`, `lng`, `source` (required) and `note`, which opens with `high` or `medium` for how sure the placement is, then names the place.

Unlike a subdivision override, a coordinate override never replaces a UN/LOCODE position, because UN/LOCODE is the source of record. It fills a gap only; once UN/LOCODE publishes a position of its own, the refresh reports the row so it can be removed. It also reports a row whose port left UN/LOCODE.

The seed rows were placed by hand from general knowledge of each port, to roughly a kilometre, then each was checked by reverse geocoding it on [OpenStreetMap](https://www.openstreetmap.org/copyright) (© OpenStreetMap contributors, ODbL; one request a second, per Nominatim's usage policy): the point must land in the port's own town, on or by its harbour. Three did not and were moved; their `note` says where they were first placed. Do the same check before adding a row, and tighten the `medium` ones against the harbour and terminal outlines when a berth matters. The build rejects a row with no source, a position off the globe, a malformed locode or a port listed twice.

After adding rows, run `rake seaports:apply_coordinates` to write them into the shipped table without a download. The next refresh rebuilds the same positions on its own.
