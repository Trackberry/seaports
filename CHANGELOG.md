# Changelog

Entries are written by `.github/workflows/refresh.yml` when it opens a refresh
pull request, or by hand for a code change; a person merges both.

## Unreleased

Canal outlines, a new kind of data beside the port outlines, for the Suez and Panama canals: each canal's centreline, the anchorages where ships wait to transit with the end each serves (`north`, `south` or `in_transit`), and its pilot boarding places, all from OpenStreetMap by id. `Seaports.canals`, `Seaports.canal("suez")` and `Seaports.canal_anchorage_at(lat, lng)` read them; see the README. `rake seaports:geometry` builds them and `rake seaports:check_geometry` checks them, including that no canal anchorage overlaps a port's limits.

A port outline for Ain Sokhna (`EGSOK`, with `EGAIS` as a quay): OpenStreetMap's port area as the limits, DP World Sokhna's terminal and the liquid bulk berths. OpenStreetMap does not map Red Sea Container Terminals yet.

Derived port limits can be cut to the water: `clip: water` under a selection's `port_limits` takes the hull of the terminals down to the sea within OpenStreetMap's coastline and the rivers, docks and basins it maps, keeping the terminals whole. Hulls that took in the towns between and behind the quays (Lyttelton, Tauranga's Mount Maunganui, Rouen's left bank) no longer do. The build refuses a terminal with no water beside it, and clipped limits in separate parts must say why (`disjoint`). Clipping uses GEOS at build time through the rgeo gem (`brew install geos`, `apt-get install libgeos-dev`, before `bundle install`); the gem itself still needs neither. Outlines without `clip` are built byte for byte as before.

The check that two ports' limits overlap now compares their shapes rather than their bounding boxes, so two ports along one lagoon no longer warn.

## 1.7.5 — 2026-11-23

Port outlines for 20 more ports, so 61 in all:

- Latin America: Moín (`CRMOB`), Paita (`PEPAI`), Posorja (`ECPSJ`), Valparaíso (`CLVAP`), San Antonio (`CLSAI`), Santa Marta (`COSMR`), Pecém (`BRPEC`) and Natal (`BRNAT`).
- Africa: Cape Town (`ZACPT`), Ngqura (`ZAZBA`) and Tanger Med (`MAPTM`).
- United States: Wilmington, Delaware (`USILG`), Philadelphia (`USPHL`), New York and New Jersey (`USNYC`), Los Angeles (`USLAX`), Oakland (`USOAK`) and Savannah (`USSAV`).
- France and Spain: Rouen (`FRURO`), Le Havre (`FRLEH`) and Seville (`ESSVQ`).

Each outline was checked against every house, residential area, school, church and hospital OpenStreetMap maps around it, not only town centres, and each limits note says what lies inside. Where one outline could not keep a town out, the port covers its main cluster and the note names what is left out: Rouen is Grand-Couronne only; Le Havre leaves out the CIM oil terminal, the cruise terminal and the Citadelle ferry berth; New York is the Newark Bay terminals, without Port Liberty New York at Howland Hook, Port Liberty Bayonne or the Brooklyn terminals; Philadelphia leaves out Tioga. Le Havre's limits take in the Les Neiges district, which the docks enclose, and Tanger Med's take in two hamlets between Tanger Med 1 and 2; both notes say so.

`USNYC` lists `USEWR` and `USPNJ` as quays. Howland Hook and Staten Island are not quays of it, because their terminal is outside these limits.

Same ports, names and positions as 1.7.4.

## 1.7.4 — 2026-11-23

Port outlines for 16 more ports, so 41 in all:

- UK and Ireland: Liverpool (`GBLIV`), Belfast (`GBBEL`), Dublin (`IEDUB`), Cork (`IEORK`), Waterford (`IEWAT`) and Rosslare (`IEROS`).
- France: Dunkirk (`FRDKK`), Montoir-de-Bretagne for Nantes-Saint-Nazaire (`FRMTX`), Marseille (`FRMRS`), Calais (`FRCQF`) and Sète (`FRSET`).
- Spain: Bilbao (`ESBIO`), Huelva (`ESHUV`), Santa Cruz de Tenerife (`ESSCT`), Tarragona (`ESTAR`) and Almería (`ESLEI`).

Rotterdam's APM Terminals Maasvlakte II now covers its southern expansion along the Prinses Amaliahaven (OpenStreetMap way 1231452162, under construction and due to open from late 2026), not only the northern quay strip.

Where a port's terminals are spread too far for one outline to keep the towns out, the outline covers the main cluster and says so: Dunkirk is Port Ouest only, Cork is Ringaskiddy only, Waterford is Belview only. Ships at the berths left out read as outside the port. Rouen was drafted and left out: its terminals run 15 km along the Seine with towns behind the quays, and no single outline covers them without taking in Petit-Couronne and Grand-Quevilly.

What OpenStreetMap does not map is left out and said so in the notes: Liverpool's Royal Seaforth container terminal, Marseille's Med Europe Terminal at Mourepiane, Montoir's container terminal, Dunkirk's fruit quays at Port Est, Almería's cargo quays. Several terminals in Dublin have no cargo type.

`OSM_SOURCE=extract rake seaports:geometry[LOCODE]` builds an outline from Geofabrik extracts with osmium instead of Overpass, with the same result; the weekly rebuild now uses it (#19).

Same ports, names and positions as 1.7.3.

## 1.7.3 — 2026-11-23

Port outlines for 14 more ports, so 25 in all:

- North Sea: Bremerhaven (`DEBRV`), Vlissingen (`NLVLI`) and Zeebrugge (`BEZEE`).
- UK: Tilbury (`GBTIL`), Sheerness (`GBSHS`), Teesport (`GBTEE`) and Immingham (`GBIMM`).
- Spain: Barcelona (`ESBCN`), Las Palmas (`ESLPA`), Cartagena (`ESCAR`), Castellón (`ESCAS`) and Málaga (`ESAGP`).
- France: Fos-sur-Mer (`FRFOS`) and Port-Vendres (`FRPOV`).

What OpenStreetMap has for them:

- Vlissingen shares the Scheldt anchorages with Antwerp (the same features), and Immingham's Hawke, Bull and Haile anchorages serve the whole Humber. No anchorage carries a category.
- Several ports have no anchorage mapped, and several terminals have no cargo type, among them Zeebrugge's car terminals.
- Some terminals are missing from OpenStreetMap as areas: Vlissingen's Kloosterboer fruit terminal, Immingham's river jetties and the Humber International Terminal, Cartagena's Escombreras basin, Las Palmas's La Luz container terminal. A ship at one of them reads as inside the port limits, not alongside.
- Tilbury and Sheerness are each mapped as one area, so their terminals are not told apart.
- Where a UN/LOCODE point lies in the town rather than the port (Bremerhaven, Teesport, Immingham, Las Palmas, Cartagena, Castellón, Fos), `position_outside` says so.

Same ports, names and positions as 1.7.2.

## 1.7.2 — 2026-11-23

Port outlines for 8 more ports, so 11 in all: Hamburg (`DEHAM`), Felixstowe (`GBFXT`), London Gateway (`GBLGP`), Southampton (`GBSOU`), Portsmouth (`GBPME`), Algeciras (`ESALG`), Valencia (`ESVLC`) and Vigo (`ESVGO`). Each comes from a reviewed selection of OpenStreetMap features, built and checked the same way as the first three.

What OpenStreetMap has for them:

- OpenStreetMap maps no port limits for any of them, so every port's limits are the hull of its terminals.
- Felixstowe is one area, not its Trinity, Landguard and Berth 8-9 terminals.
- The anchorages of Hamburg (on the Elbe), Felixstowe (Harwich Haven) and Valencia carry no category. Hamburg's and Felixstowe's also serve their neighbours: Brunsbüttel, Cuxhaven and Stade on the Elbe, Harwich and Ipswich in the haven.
- London Gateway, Southampton, Portsmouth, Algeciras and Vigo have no anchorage mapped.
- Some terminals are mapped as a building or a pier rather than the quay, so a ship moored alongside can fall outside the terminal and only inside the port limits: Southampton's fruit terminal and the Fawley jetty, Portsmouth's Wightlink berth, Valencia's Trasmed terminal and the Algeciras refinery jetty.
- Several of Hamburg's terminals have no cargo type, and Algeciras's ferry and ro-ro terminal is not mapped as a terminal.
- Valencia leaves out Sagunto, which is its own locode (`ESSAG`) with no terminal mapped.

Each outline now carries `selection_digest`, a fingerprint of the selection it was built from, and `rake seaports:check_geometry` fails an outline whose selection changed without a rebuild. On a pull request, `.github/workflows/geometry.yml` fetches from OpenStreetMap only the ports whose outline does not match its selection, with two tries of ten minutes each, and one port that fails no longer stops the rest. A batch of ports built locally then checks in seconds rather than spending most of an hour on Overpass. The weekly rebuild still fetches every port.

Same ports, names and positions as 1.7.1.

## 1.7.1 — 2026-11-23

Antwerp's outline no longer includes "Containerkade" (Katoen Natie, OpenStreetMap way 376648236), a quay in the Western Scheldt near Vlissingen, 32 km from Antwerp's nearest terminal. It came from the search around Vlissingen used for the anchorages. Because the port limits are derived from the terminals, they had stretched down the river to take it in, so `Seaports.within?("BEANR", …)` answered true for ships off Terneuzen. Antwerp now has 7 terminals and its limits end at Doel and Zandvliet.

The checks now refuse a terminal more than 25 km from every other terminal of its port, which would have caught it.

## 1.7.0 — 2026-11-23

Port outlines, for three ports to start: Rotterdam, Antwerp and Dover. `Seaports.geometry(locode)` is the port as GeoJSON, and `Seaports.areas`, `terminals`, `anchorages` and `port_limits` are its features as `Seaports::Geometry::Area`s, each with a kind, name, operator, cargo type, anchorage category, the OpenStreetMap ids it came from, `source`, `licence`, `reviewed_at` and a note. `Seaports.within?(locode, lat, lng, kind:)` and `areas_at` say whether, and in which area, a position is; `Seaports.ports_at(lat, lng)` names the ports whose limits hold it; `Seaports.quays(locode)` lists the locodes that are parts of the port (`NLBOT` for Rotterdam). A port with no outline answers `nil`, `[]` and `false`.

No coordinate in them was typed or generated. A reviewed selection per port, `data/geometry/sources/<LOCODE>.yml`, names OpenStreetMap features by id, and `rake seaports:geometry` fetches their shapes and checks them; `rake seaports:geometry_candidates` lists the features a selection can choose from. OpenStreetMap maps no port limits for any of the three, so their limits are the hull of their terminals, said so in `source`. `.github/workflows/geometry.yml` builds the outline on a pull request that edits a selection and refreshes every port weekly.

The outlines are © OpenStreetMap contributors under the ODbL 1.0, a data licence separate from the gem's MIT code: see `data/geometry/LICENSE.md`. The gemspec now lists both licences.

What the prototype found in OpenStreetMap: Rotterdam and Antwerp are well mapped (every deep-sea container terminal, the Scheldt and Maasmond anchorages, the Kloosterboer cold stores), but no anchorage carries a category and several Antwerp terminals have no cargo type. Dover has its Eastern Docks and its basins, and no anchorage or Western Docks cargo terminal.

Same ports, names and positions as 1.6.1.

## 1.6.1 — 2026-11-21

Five more alternate names are refused, so 659 of 17,567 ports have alternate names, down from 662:

- USROC no longer answers to "Charlotte": it is the Rochester neighbourhood at the port, but the name clashes with Charlotte, North Carolina, a common inland destination.
- TNLSK no longer answers to "Qabes", the name of Gabès (TNGAE).
- ESSAG no longer answers to "El Puerto", which is generic and also El Puerto de Santa María.
- JPUNO no longer answers to "Tama", a district of Tamano near the port, not the port's name.
- GBSHO no longer answers to "New Shoreham", an obsolete name for Shoreham-by-Sea that is also used today for Block Island, Rhode Island.

Same ports, names and positions otherwise.

## 1.6.0 — 2026-11-21

Ports now carry their other names. `Seaports.find("BEANR").alternate_names` is `["Antwerp", "Anvers"]`, where `name` is UN/LOCODE's `Antwerpen`; `Seaports.alternate_names(locode)` is the shortcut, and `[]` answers for a port with none. 662 of 17,567 ports have at least one.

The names come from three places, best first: a reviewed list, `data/sources/alternate_names.csv` (Genoa, Dunkirk, Bombay, Rangoon and 10 more the other sources lack); the [NGA World Port Index](https://msi.nga.mil/Publications/WPI)'s "Alternate Port Name" column, split on `;` and `,` (public domain, credited as NGA asks), skipping a locode that is not in the table or is on more than one index row, and filtering vessel, terminal, base, company and country names and fragments; and the name in the parentheses of UN/LOCODE's name (`El Iskandariya (Alexandria)`), for ports with a position, when it is one plain name. Spellings that differ only in case, accents or punctuation count as one, and a name equal to the port's own is dropped.

A main name always beats an alternate: a name that is another port's own name in the same country is dropped, and so is one that two or more ports of a country share (`Bruxelles` on three Belgian ports), also comparing with a port's name without a trailing Pt, Port or Harbour and with each part of a `/` or `,` name. The names are filtered and reviewed: `data/sources/alternate_names_rejected.csv` lists wrong-place names a person has refused. They are still not checked against the place, so a few are a bay or a point near the port.

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
