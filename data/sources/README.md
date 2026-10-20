# Build inputs

Files here feed `rake seaports:refresh` and are not shipped in the gem; only the table they help build is.

## subdivision_overrides.csv

Reviewed ISO 3166-2 subdivisions for ports that neither UN/LOCODE nor Natural Earth's map places, such as Valencia, Algeciras and Barcelona, which have no subdivision and no position in UN/LOCODE. An override wins over every other source, so a row should be removed once UN/LOCODE publishes a subdivision of its own; each refresh lists the rows that have reached that point.

The rows were suggested by `script/suggest_subdivision_overrides.rb` and checked by a person. The `note` column quotes the place each search matched, or explains a manual correction.

Those place names come from [OpenStreetMap](https://www.openstreetmap.org/copyright) through its Nominatim search: © OpenStreetMap contributors, available under the Open Database Licence (ODbL).
