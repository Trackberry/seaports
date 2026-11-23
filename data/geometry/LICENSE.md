# Port outlines: data licence

The files in this directory, `data/geometry/*.geojson` and the selections in `data/geometry/sources/`, and the canal outlines in `data/geometry/canals/*.geojson` with their selections in `data/geometry/canals/sources/`, are a database derived from [OpenStreetMap](https://www.openstreetmap.org/).

They are © OpenStreetMap contributors and Trackberry, and are made available under the [Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/). Any rights in individual contents of the database are licensed under the [Database Contents License](https://opendatacommons.org/licenses/dbcl/1-0/).

In short, and the licence itself governs:

- **Attribute.** Credit "© OpenStreetMap contributors" wherever you show or publish these outlines, for example in a map's attribution line.
- **Share alike.** If you publish an adapted version of this database (outlines you corrected, merged or extended), publish it under the ODbL too.
- **Keep it open.** You may not apply technical measures that restrict others' use of a published copy unless you also publish an unrestricted one.

A map, a report or a decision made with the outlines is a "produced work" and may be published under any terms, with the attribution above.

The gem's code, everything outside this directory, keeps its own MIT licence in `LICENSE.txt`. The two are separate: using the code does not make your code subject to the ODbL, and the ODbL applies to the outlines however you obtain them.

## Other sources

- Port positions used by the checks come from the gem's own table (UN/LOCODE, the NGA World Port Index, which is in the public domain, and Wikidata, which is CC0).
- Derived port limits (`"source": "Derived: ..."`) are computed from the OpenStreetMap features of the same port, so they fall under the ODbL with them.
- Nothing here comes from Global Fishing Watch, whose anchorages are CC BY-NC, or from positions in a commercial AIS feed.
