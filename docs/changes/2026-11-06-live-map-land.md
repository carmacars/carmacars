# Live map: a real map of the land, Hamilton to Barrie (0311)

Release 26. The owner, on the Release 25 TV view: "the map focuses more on the water than on the land and we're
literally trying to display cars. It needs to look nicer." Then his exact spec: look like a real map (an outline of
each city or municipality, roads as well as the highways), and zoom in a little: Hamilton the furthest point south,
Barrie the furthest north, Toronto in the middle if possible; pins kept clear of the overlays. His first ask still
stands: a GTA map going further out than Hamilton, a pin per lead type, an impressive look for a TV, and car photos.

What was wrong: the first view ran from Niagara to Cobourg, so Lake Ontario filled the middle and the bottom right and
the pins sat squeezed on its western edge. The view only ever widened. The lake was a bright blue with a glowing shore,
so the eye went to the water. The map had no city outlines and only the 400-series highways. The legend chips sat over
the map's top left, and round photo pins on one spot (home base and a Toronto renter, or several home-city renters)
covered each other.

## Framing

- **The owner's box** (`HOME_BOUNDS`): Hamilton (43.245) at the bottom, Barrie (44.395) at the top, centred on Toronto
  east to west. The TV's width then takes in Kitchener to Oshawa and beyond. It is framed edge to edge inside the room
  the four numbers and On the road leave (measured from the screen, plus one line for a city's name over On the road).
- **Pins stay clear of the UI:** when, with the box framed, a photo pin (its half size counted) would sit under the
  numbers or On the road, the map frames the box and every pin instead (`frameBounds`), still centred on Toronto (one far
  pin widens both sides). `data-frame` says which (`home` or `pins`).
- **Never closer than a city** (`FRAME_MAX_ZOOM` 9.6). A new screen size frames again; a move to a new frame glides over
  2.4 seconds (at once with reduced motion). The existing motion (breathing dots, the arcs, the home base pulse) is kept.
- The stage chips moved off the map onto On the road's title line, so the map keeps its height.

## The map

`web/public/live-map/regions.geojson` (69 KB, `web/scripts/live-map/regions.mjs`):

- **Every city and town outlined:** Statistics Canada's 2016 census subdivisions through geoBoundaries (ODbL 1.0,
  Statistics Canada Open Licence), Kitchener to Peterborough and Niagara to Barrie and beyond. Each shared border is
  simplified once (the TopoJSON idea), so neighbours meet exactly; the GTA's finer, the land round it coarser. Borders
  are a fine dotted line; the borders of the GTA's regions (Toronto, Peel, York, Durham, Halton, Hamilton) a clear soft
  line with a faint glow; the GTA's municipalities a shade lighter than the land round them; the region names faint.
- **Roads:** 27 major arterials (Yonge, Bloor and Danforth, Eglinton, Lawrence, Sheppard, Finch, Steeles, Highway 7,
  Major Mackenzie, Lake Shore, Dundas, Hurontario, Kingston Road and Highway 2, Taunton, Simcoe, Trafalgar, Brant and
  Guelph Line, Hamilton's Main Street and Upper James, Markham Road and Highway 48, Don Mills, Keele, Kennedy, Airport,
  Burnhamthorpe, and Barrie's Bayfield and Essa) as fine cool grey lines under Release 25's amber highways. Drawn by
  hand from public knowledge of their routes, about 1 km accurate: the texture of a wall map, not directions.
  CarmaCars' own work. (No OpenStreetMap extract could be reached from the build machine; the file's format takes one
  later without a code change.)
- **Names:** the cities widely letter-spaced; the owner's list (Richmond Hill, Burlington, Pickering, Ajax, Whitby,
  Milton, Newmarket, Aurora) at the size of the smaller cities; 14 towns smaller. Each sits far enough from its spot to
  clear a photo pin there, and gives way to the pins.
- **A glow where people live:** a heatmap of points inside each populated municipality, weighted by people per km² (2021
  census, rounded). **Relief:** the Niagara Escarpment and the Oak Ridges Moraine as a soft rise with a faint crest,
  drawn by hand. **The lead heat** sits on the land. All three are under the water, so the light stays on land.
- **The water** is near black with one fine shore line. On a TV a soft vignette lets the edges fall away.
- The credits (Natural Earth; Statistics Canada via geoBoundaries (ODbL); CarmaCars) start folded behind their (i).

Everything is served by the site itself: no new host, no change to the security policy.

## The pins and the photos

- **A photo pin is a small landscape card** (80 by 54 px at 1080 lines, 160 by 108 at 4K; 0.8 of that on the page, 0.6
  on a phone) framed in its stage colour, so the car shows whole. A hot lead not yet booked is a little smaller with a
  rose ring; a booked or rented car keeps its stage colour clean.
- **Pins that would cover each other make room** (`model.separate`): pins on one spot first form a tidy block of rows
  centred on it, then each overlapping pair moves apart along the cheaper axis; home base never moves. A pin moved
  aside has a fine line in its stage colour back to a small dot on its spot. The same pins give the same layout every
  refresh. The labels' keep-out boxes follow the cards where they are drawn, in the cards' shape.

## Checked

- Screenshots from the design harness (the real component and styles, fake data, example.test only) at 1920 by 1080
  and 3840 by 2160 (TV), the admin page at 1440 and 375, and a stacked case (five cars on home base's spot): no photo
  pin covers another or sits under the numbers or On the road, no horizontal scroll.
- Unit: the box (Hamilton bottom, Barrie top, centred on Toronto), `frameBounds` (a pin inside changes nothing, a far one
  widens both sides), `separate` (a lone pin stays, five on one spot with home base, the same answer in any order),
  `regions.geojson` (size, attribution, the six regions and their cities, Barrie outlined, the arterials and the owner's
  cities, the glow and the ridges).
- End to end (`live-map.spec.ts`): at 1080p and 4K the zoom stays at or under the cap and the photo pins are clear of
  each other and of the numbers and On the road; `regions.geojson` loads from the site.

## Guides

- `admin/live-visitors-and-live-chat`: Live map (the area, the outlines and roads, the photo cards, the stage chips).
  Published by migration 0311 (`supabase/seed/0311_gen_guides.mjs`).
