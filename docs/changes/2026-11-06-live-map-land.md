# Visitors: one page for the live map, Live now and History; a real map of the land, clickable named leads, Show contact, and a map without WebGL (0311)

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

## Clickable leads, names and Show contact

The owner: "the leads on the map should be clickable and they should show names and there should be a toggle to show
their phone numbers and emails too or hide that", and "when hovering a cursor over a lead, it should temporarily open
the card while it's hovered over".

- **Every lead opens its card:** the dots (game, unfinished form, form sent, request, booking, on rent, past renter, on
  the site), the car cards, and on the TV the live feed and On the road. The card: the full name, the stage, the score
  with every signal, the car last viewed with its photo, the city, minutes on the site or when last seen, the phone and
  email when Show contact is on, and a link into Admin (the booking, else the renter, else Live visitors, else Renter
  leads searched by the name; `model.adminHref`). × or Escape closes it; on a TV it closes by itself after 20 seconds
  and the map goes back to its frame (also 20 seconds after a count was opened). The TV's map now listens for clicks
  but still never pans or zooms by hand.
- **Scrolling to the map** ("Show on the map" from the list) is smooth, or at once for someone who asked for less
  motion (the hover check in CI measured the map while a long smooth scroll was still moving it).
- **The map stays put on the page:** once a lead was shown on the map, a count opened or the map moved by hand, new
  pins arriving with the 30-second refresh no longer re-fit it (a TV still re-fits, and goes back to its frame when a
  card closes).
- **Hover previews:** resting on a lead (or reaching a car card with Tab) shows its card after 150 ms, anchored to the
  pin; leaving hides it after 300 ms, time enough to move onto the card. A click (a tap on a touch screen) pins it.
- **Names:** the first name and last initial on the dots (beside each, real names before visitors, giving way when
  there is no room) and along the foot of each car card; the full name in the card and the page's table; "Visitor in
  Mississauga" for an anonymous visitor. Names are sent always (the TV included); `Show details` is gone.
- **Show contact** (a switch above the map, and at the top of the TV's side panel): off by default, remembered per
  device (`localStorage`, wrapped so a private window or blocked storage just keeps it for the visit). While it is off
  the answer has no phone or email at all, not even the last digits (the earlier "ending 0142" is gone): the page is
  drawn without them and `/api/staff/live-map` sends them only with `?contact=1`. Turning it off takes them out of the
  page at once (`model.withoutContact`) and the next read has none. Who: Admins (two-step when required), the same
  check as the renter and lead pages (`requireAdmin` there, `assertAdmin` here; `admin_read live_map` asserts the Admin
  again in the database).

## Hottest lead: leads only

The owner, on the TV's "Hottest lead" showing someone on rent: "that doesnt even make sense lol thats not a lead thats
a rental". `model.isLead`: a game player, a form started or sent, a request, a visitor on the site, or a past renter back
browsing; never someone on rent or with a confirmed booking to come (as their stage or any other of theirs), nor a
request whose offer was accepted and is awaiting payment. The spotlight takes leads only, by score, and shows why (the
three strongest signals); with no lead it says "No hot leads right now" and never falls back to a renter. The same rule
decides the hot lead's car card and rose ring, the hot glow under a dot, and the hot or warm colour of a score (a
renter's score shows plain) on the map, the cards and the page's table.

## One page: Visitors

The owner: "The visitor history tab looks awful btw. And again u have redundant and ugly tabs. Like why is there live
visitors, visitor history and live map all as separate tabs. U can merge all 3 into one and make the whole thing more
appealing."

- **Today > Visitors** (`/admin/visitors`) replaces Live visitors, Visitor history and Live map in the menu (one entry,
  with the hot visitors' count the Live visitors entry had). The map on top, as it was, with its hover and click cards
  and Show contact; under it one white panel with a black switch, **Live now** or **History**.
- **Live now** is Live visitors (the same rows and every action: chat, the suggested message, the discount code, assign
  to Sales, a similar free car, naming a visitor, the pages of the visit, hot visitors today, the signals of 24 hours,
  the most viewed cars), with an icon per kind of visit (in a chat, form sent, unfinished form, known customer, on the
  site), filters by type, city and source, and **Show on the map** (the icon too): the map brings the lead to its middle
  and opens its card. The five tiles became one line (the map has the big numbers).
- **History** is Visitor history as cards, not a table: an icon for what the visit led to, the name, chips (request,
  booking, contact, visit number), where it came from, the pages, how long, the device and place, the time, "Open the
  visit". The filters that matter in one row (dates, what it led to, city, source or campaign), the rest under "More
  filters"; the totals, chart and top lists folded under "Totals and day by day". A visit's icon finds it on the map when
  it is still there.
- **Show contact** covers the list too: with it off, `/api/staff/live` (asked with `contact=0` by this page) and the page
  as the server draws it carry no phone or email (what a visitor typed, a named visitor's phone and email, a visitor
  known only by an email: `features/live/contact.ts`). Changing a named visitor's details waits for the switch, so the
  form never saves blanks over them. The assistants' Live visitors (`/staff/live`) is unchanged.
- **Old addresses:** `/admin/live` goes to Live now, `/admin/live/history` to History with its filters, `/admin/live-map`
  to the page; `/admin/live-map?tv=1` stays TV mode (the TV's bookmark), opened by **Open TV mode**. A visit's own page
  (`/admin/live/history/<id>`) and Signal settings stay where they were. Who may open each is unchanged: Admins.

## Without WebGL

The owner's laptop showed "The map needs WebGL" and no map. Now the map always draws:

- **`canvas.ts`** draws the same map with Canvas 2D from the same three files, projected with Web Mercator as MapLibre
  does (a 512 px world at zoom 0, the same fit sums), so the framing, the land, the outlines, the glow, the ridges, the
  lake, the roads and highways, the names, the dots (gathered into counts where they crowd), the car cards (moved apart
  the same way), home base and its arcs, the cars, the hover and click cards and Show contact all match.
- **Picked by itself:** WebGL when the browser has it and MapLibre starts; otherwise (no WebGL, Chrome's software
  rendering blocklist, hardware acceleration off, or MapLibre failing to start) the Canvas map. The map says which in
  `data-renderer="webgl|canvas"`. In the Canvas map a small note in the corner reads "Faster with hardware acceleration
  on (Chrome Settings > System)". The old WebGL message shows only if both fail.

## Checked

- Screenshots from the design harness (the real component and styles, fake data, example.test only) at 1920 by 1080
  and 3840 by 2160 (TV), the admin page at 1440 and 375, and a stacked case (five cars on home base's spot): no photo
  pin covers another or sits under the numbers or On the road, no horizontal scroll.
- Unit: the box (Hamilton bottom, Barrie top, centred on Toronto), `frameBounds` (a pin inside changes nothing, a far one
  widens both sides), `separate` (a lone pin stays, five on one spot with home base, the same answer in any order),
  `regions.geojson` (size, attribution, the six regions and their cities, Barrie outlined, the arterials and the owner's
  cities, the glow and the ridges).
- End to end (`live-map.spec.ts`): at 1080p and 4K the zoom stays at or under the cap and the photo pins are clear of
  each other and of the numbers and On the road; `regions.geojson` loads from the site. A lead opens its card from the
  table's "Show on the map", from a hover (a preview, gone when the pointer leaves) and from a click on its dot (pinned),
  and from the TV's live feed. Show contact: off by default, no phone or email in the page's HTML or the map's JSON;
  on, they are asked for (`contact=1`), shown and remembered; off again, gone at once. With WebGL disabled in the
  browser (`getContext('webgl')` returning nothing), the map draws in Canvas, shows its note, its dots open their cards
  and nothing is logged as an error.
- End to end: the old addresses land on Visitors (Live now, History with its filters); the menu has Visitors and none of
  the three; Live now hides the phone and email of what Erin typed until Show contact, in the page and in the reads; a
  row's "Show on the map" opens the lead's card (`live-map.spec.ts`); History's cards, filters and "More filters", and
  the visit's page (`visitor-history.spec.ts`); Live chat's menu entry (`live-chat.spec.ts`).
- Unit: Show contact off for live visits (`features/live/contact.test.ts`); History's addresses.
- Unit: a renter (on rent, booked, or paying an accepted offer) is never the hottest lead, whatever the score; an
  empty spotlight with no leads; no hot-lead card for a renter.
- Unit: names and contact (`toView`, `withoutContact`, nothing of a phone or email in the JSON while off),
  `adminHref`, the card's time line, the Mercator sums the Canvas map shares with MapLibre.

## Guides

- `admin/getting-around-admin`: the Today menu (Visitors).
- `admin/live-visitors-and-live-chat`: Live map (the area, the outlines and roads, the photo cards, the stage chips).
  Published by migration 0311 (`supabase/seed/0311_gen_guides.mjs`).
