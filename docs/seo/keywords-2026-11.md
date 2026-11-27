# Keyword research, November 2026

Release 50 hotfix 2. Every keyword cluster worth targeting, the page that answers it, and what changed. Written Nov 27, 2026.

## Sources and limits

- **Search Console, stored by the gsc workflow** (run 45924183998, Nov 27 01:43 UTC): 1,222 clicks and 83,157 impressions
  from Aug 28 (38 days with data); 5,000 searches and 5,000 pages stored for Oct 28 to Nov 24 (`app.gsc_page_query`).
  The searches themselves could not be read for this document: the session had no database access and no connector tool
  read them. Fixed in this release: the connector tool `search_console_queries` (admin:read, migration 5160) and the
  100 searches with the most impressions in every gsc run's summary (`web/scripts/gsc-pages.mjs`). The next revision of
  this file ranks each cluster by those figures.
- **Search Console coverage** (search_console_issues, Nov 27): 150 pages inspected, 46 known to Google, 0 indexed of
  those, 43 discovered not indexed, 3 crawled not indexed; across all inspections 6,165 unknown to Google and 2,125
  discovered not indexed. 500 sitemaps hold 10.1 million addresses. Google discovers far more than it crawls: the gain
  is in the few pages each cluster needs, linked from many places, not in more addresses.
- **Leads** (list_leads, Nov 17 to 27, 200 newest): no lead from the tracker or chauffeur forms; 124 unfinished forms, 20
  discount game, 19 expired offers, 16 chats, 11 owner program.
- **Public sources**: Ontario OPCF 27 explainers by insurers and brokers ([Sonnet](https://www.sonnet.ca/blog/auto/insurance/opcf-27-explained),
  [BrokerLink](https://www.brokerlink.ca/blog/opcf-27), [PolicyMe](https://www.policyme.com/car-insurance/opcf-27),
  [FSRA form](https://www.fsrao.ca/media/6411/download)); GTA auto theft and trackers
  ([CBC](https://www.cbc.ca/lite/story/1.7086626), [CTV](https://toronto.ctvnews.ca/brampton-man-saved-by-second-gps-tracker-after-thieves-rip-out-his-first-one-1.6751805),
  [CBC 2025](https://www.cbc.ca/lite/story/1.7595080)); rental software directories that rank for software searches
  ([Capterra](https://www.capterra.com/car-rental-software/), [G2](https://www.g2.com/categories/car-rental),
  [GetApp](https://www.getapp.com/retail-consumer-services-software/car-rental/org/small-business/)).
- No keyword tool volumes were available. Priority is by intent (how close the search is to a lead) and by what the
  site can answer with facts.

## Clusters and pages

Priority: A (a lead or booking intent we can serve now), B (supporting, links to A), C (long tail, programmatic).

| Cluster | Searches (examples) | Intent | Priority | Page | Status |
|---|---|---|---|---|---|
| Car rental, Toronto | car rental toronto, rent a car toronto, cheap car rental toronto, car hire toronto | Book | A | `/car-rental`, `/car-rental/toronto`, `/cars` | Exists. Every SEO page now ends with the four offers (tracker, owner, chauffeur, rental). |
| Car rental, GTA places | car rental mississauga, brampton, markham, vaughan, scarborough, north york, etobicoke, richmond hill, oakville | Book | A | `/car-rental/<place>` (place hubs) | Exists; nearby and child places linked. Delivery fee and distance shown. |
| Airport | car rental pearson, yyz car rental delivery, billy bishop car rental | Book | A | `/airport-car-rental/yyz`, `/airport-car-rental/ytz` | Exists. |
| Delivery | car rental delivery toronto, car rental delivered to my house | Book | A | `/delivery`, `/car-rental/car-delivery` | Exists. |
| Long term | monthly car rental toronto, long term car rental, weekly car rental, car rental for a month | Book | A | `/car-rental/monthly`, `/car-rental/weekly`, place hub term `long-term-car-rental` | Exists. |
| Insurance replacement | insurance replacement car rental, rental car while my car is in the shop, collision replacement car, loaner car | Book (insurer pays) | A | `/car-rental/insurance-replacement`, hub terms `insurance-replacement-rental`, `collision-replacement-car`, `rental-car-while-car-is-in-the-shop`; `/body-shop` leads with it | Exists. Body shop pages carry the "your car is in the shop" band. |
| OPCF 27 | opcf 27, opcf 27 rental car, does my car insurance cover a rental car ontario, rent a car with my own insurance | Book | A | `/car-rental/opcf-27` | **New** (migration 5163). Linked from `/requirements` (coverage table), `/credit-card-rental-coverage` and the coverage card on every SEO page. |
| Coverage | credit card rental car insurance canada, car rental with insurance included | Book | B | `/credit-card-rental-coverage`, `/car-rental/insurance-included`, `/requirements#coverage` | Exists; now links OPCF 27. |
| Young and new drivers | car rental under 25 toronto, rent a car at 18, g2 car rental | Book | A | `/car-rental/young-drivers`, `/car-rental/under-25`, `/car-rental/g2-licence` | Exists. |
| Rideshare | rent a car for uber toronto, car rental for lyft, delivery driver car rental | Book | A | `/car-rental/rideshare` | Exists. |
| Owner program | rent out my car toronto, earn money with my car, list my car for rent, turo alternative canada, car sharing host toronto | Owner lead | A | `/list-your-car`, `/list-your-car/apply`, `/car-rental/turo-*-alternative` | Exists. Every SEO page now carries "List your car and earn" first or second, linking straight to the application. |
| Trackers | gps tracker for car canada, car kill switch toronto, anti theft device for car, starter interrupt, gps tracker for rental car, turo host gps tracker, fleet tracking | Tracker lead | A | `/trackers` and its intent pages (`/trackers/kill-switch-for-car`, `starter-interrupt-device`, `gps-tracker-for-rental-car`, `anti-theft-tracker-toronto`, `fleet-tracking`, `turo-host-gps-tracker`, `toll-and-ticket-billing`), `/trackers/install/<place>` | Exists, but **was in no working sitemap**: `/sitemap-families.xml` answered an empty file (GSC error, last read Nov 26). Fixed: the tracker pages are in `/sitemap-pages.xml`; the tracker card now opens the waitlist form (`/trackers#waitlist`) from every SEO page family. |
| Chauffeur | chauffeur service toronto, car with driver toronto, wedding car rental toronto, airport chauffeur | Chauffeur request | A | `/chauffeur`, `/chauffeur/request`, hub terms `chauffeur-service`, `car-with-driver` | Exists. The chauffeur card now opens the request form from every SEO page family. |
| Events | car rental for tiff, cne parking car, raptors game car | Book | C | `/events/<event>` | Exists. |
| Buying help | used cars toronto, car financing, lease takeover | Lead (finance) | C | `/buy/<term>/<place>`, `/buy/<make>/...` | Exists; now carries the four offers (rent it before you buy). |
| Detailing and body | mobile detailing toronto, ceramic coating, bumper repair, collision repair mississauga | Lead | B | `/detailing`, `/body-shop`, `/detailing/<term>/<place>`, `/body-shop/<term>/<place>` | Exists; lead with a rental offer and now the four offers. |
| Vehicle pages | toyota camry rental, 2022 honda civic specs, bmw x5 rental toronto | Book (some) | C | `/cars/<make>/<model>...`, `/t/<term>/...` | Exists; `/t/<term>` index and `/buy` index now carry the offers. |
| Rental software | car rental software, rental car management software, white label car rental software, fleet rental software canada, turo host software | B2B lead | B | `/rental-software` | **New**. Indexable, in `/sitemap-pages.xml` and `llms.txt`, in no menu. Pricing only through its form (a lead, topic "Rental software"). |

## Internal links added

- Every SEO page family (`/car-rental` and its places and terms, `/t/...`, `/buy` and its trees, `/places` and its pages,
  `/detailing`, `/body-shop` and their place pages, `/cars/...` vehicle pages, landing pages) carries the services
  module with the tracker, the owner program, the chauffeur and a car rental first (`web/src/features/services/catalog.ts`
  `LEAD_KEYS`), each linking to the page's form.
- OPCF 27: from the coverage table of `/requirements`, the card limit note of `/credit-card-rental-coverage` and the
  coverage card's cluster list.

## Next revision

1. Read `search_console_queries` (connector) or the gsc run summary: put the real impressions and positions in the table,
   and promote clusters with impressions at positions 8 to 20 (the rewrite queue of 2640 already does this for landing
   pages and guides).
2. Watch `/sitemap-pages.xml` in Search Console: the tracker and software pages should move from unknown to discovered
   within days of the deploy.
