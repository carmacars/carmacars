# 14. SEO plan

> **Changed by migration 0061 (October 19, 2026, the owner's decisions; `docs/changes/2026-10-19-seo.md`).** Listing copy,
> landing pages and guides are written by Workers AI from the database's facts and published by themselves when they pass
> the checks (lengths, house style, no number or claim the facts do not support, no near copy of another page); a person
> may edit and nobody has to. This replaces the rules below that machine-written text is never published without a
> person's edit (sections 1, 4, 17, 20). Landing pages live at `/car-rental/<slug>` (places and uses side by side), a use
> page is indexed only with enough real matching cars, and FAQPage markup is used on landing pages and guides (no rich
> result is expected; it describes the visible questions). The sitemap is an index of four files; sitemap pings are not
> sent (Google retired its endpoint), IndexNow is.

Owner: workstream B (`src/features/seo/`, `src/app/(public)/`, `content/`). The owner's goal: every car page should rank highly, and CarmaCars should become the top-ranking car rental company in Canada. This file is the plan to pursue that, and section 19 is the honest statement of what code can and cannot deliver.

Google guidance cited here was read on October 7, 2026. Links are in section 22. Where a recommendation is our judgment rather than Google's documentation, it says so.

## 1. Strategy in one page

| # | Decision | Reason |
| --- | --- | --- |
| 1 | Win specific searches first, broad ones later | "Car rental Toronto" is held by national brands and aggregators with decades of links. "2023 Tesla Model 3 rental Toronto", "car rental with a G2 licence", "monthly car rental Mississauga", "insurance replacement rental Toronto" are winnable in months with better pages |
| 2 | Every car page is a complete, unique answer | It is the page type CarmaCars has that aggregators do not: a real, specific car with its own photos, price, calendar, rules and reviews |
| 3 | Location pages exist only where CarmaCars actually operates or delivers | Google's spam policies name pages "created to rank for specific, similar search queries" as doorway abuse. A page per suburb with swapped names is that. A page with real delivery details for a place we serve is not |
| 4 | Local presence is built outside the site too | Local results depend on the Business Profile, reviews and citations, not only on pages |
| 5 | Speed is a feature | Static pages on Cloudflare's edge make good Core Web Vitals cheap; we protect them with a budget |
| 6 | No tricks | No hidden text, no bought links, no review incentives, no machine-written pages at scale. Each of these risks the whole domain |
| 7 | Expand city pages only with operations | Other Canadian cities get pages when cars are based or delivered there. "Top in Canada" follows the fleet, not the sitemap |

## 2. Site architecture and URL scheme

Lower case, hyphens, no trailing slash, no file extensions, no dates in URLs. One canonical host: `https://carmacars.ca` (the `www` host and `http` redirect with 301).

| Page type | URL | Example | Target searches | Count at launch |
| --- | --- | --- | --- | --- |
| Home | `/` | | Brand; "car rental Toronto" (long term) | 1 |
| Fleet | `/cars` | | "rent a car Toronto", browse intent | 1 |
| Car | `/cars/[slug]` | `/cars/2022-toyota-corolla-le-grey-k3f9` | "[year] [make] [model] rental Toronto" | One per published vehicle |
| Model hub | `/rent/[make]-[model]` | `/rent/toyota-corolla` | "[make] [model] rental Toronto", "rent a [model]" | One per model with at least one car |
| Make hub | `/rent/[make]` | `/rent/tesla` | "[make] rental Toronto" | Only for makes with 2 or more models or 3 or more cars |
| Category | `/car-rental/[category]` | `/car-rental/suv`, `/car-rental/electric`, `/car-rental/7-seater`, `/car-rental/luxury`, `/car-rental/economy` | "SUV rental Toronto", "electric car rental Toronto" | Only categories with 2 or more cars |
| Need | `/car-rental/[need]` | `/car-rental/under-25`, `/car-rental/g2-licence`, `/long-term-car-rental`, `/insurance-replacement` | "car rental under 25 Toronto", "monthly car rental" | 4 to 6, each a real policy page |
| City | `/car-rental/[city]` | `/car-rental/toronto`, `/car-rental/mississauga` | "car rental [city]" | Toronto at launch; each other GTA city only when delivery there is offered and priced |
| Neighbourhood | `/car-rental/toronto/[neighbourhood]` | `/car-rental/toronto/north-york` | "car rental North York" | Only the areas where cars are based or a delivery point exists; expect 3 to 6 at launch |
| Airport | `/airport/[code]` | `/airport/yyz` | "car rental Pearson airport", "YYZ car rental delivery" | Only airports with a confirmed, lawful meeting procedure (open question in `99-traceability.md`) |
| Guide | `/guides/[slug]` | `/guides/407-etr-tolls-in-a-rental-car` | Informational searches renters make | 5 at launch, 2 a month after |
| Owner programme | `/list-your-car` | | "rent out my car Toronto", "Turo alternative Toronto" | 1 |
| Reviews | `/reviews` | | Brand plus "reviews" | 1 |
| Company and legal | `/about`, `/how-it-works`, `/faq`, `/contact`, `/terms`, `/privacy`, `/cancellation-policy`, `/rental-agreement` | | Trust; brand searches | 8 |

Hierarchy and breadcrumbs: Home > Cars > [Category] > [Year Make Model]; Home > Car rental > Toronto > North York; Home > Rent > Toyota > Corolla. Every page is within three clicks of the home page.

**Not indexable:** `/book`, `/account`, `/owner`, `/investor`, `/admin`, `/va`, `/field`, `/go`, `/r`, `/unsubscribe`, `/sign-in`, `/sign-up`, and any URL with a query string.

**Other Canadian cities.** The scheme already fits them: `/car-rental/ottawa`, `/car-rental/vancouver`, `/airport/yvr`. A city page is created only when all three are true: a car is physically based there or delivery is offered there at a stated price; there is a local pickup point or meeting procedure; and the page can carry content specific to that city written by someone who knows the operation. A city in another province also needs that province's tax, licence and insurance rules in the product first (the platform is Ontario-only today). French-language pages (`/fr/`) with `hreflang` are required before Quebec. Until then no page targets a city CarmaCars does not serve.

## 3. Location pages without doorway pages

Google's spam policy: "Doorway abuse is when sites or pages are created to rank for specific, similar search queries," with the example of "generating pages to funnel visitors into the actual usable or relevant portion of a site." Its helpful-content guidance says systems "prioritize helpful, reliable information that's created to benefit people, and not content that's created to manipulate search engine rankings."

So each location page must pass these build-time checks (`01-public-site.md` section 4.4), or it is not built:

| Requirement | Enforced by |
| --- | --- |
| CarmaCars really serves the place: a based car, a delivery fee, or a pickup point | Front matter `delivery: yes` or `pickup_points`, and at least one published car whose `home_area` or delivery zone includes it |
| At least 250 words unique to the place | A similarity check across all location pages: under 40% shared 5-word sequences with any other location page, or the build fails naming both pages |
| Place-specific facts a renter needs | Front matter fields that must be filled: delivery time from base, delivery and pickup fee from the rate cards, named meeting points (for example a transit station exit or a parking lot we use), where to park at return, the nearest 407 ETR ramps and what tolls cost a renter (amount plus the $15 administration fee), winter notes if relevant |
| Real inventory | The page lists the actual cars available there with live prices, not a generic grid |
| Real proof | Reviews from rentals delivered there, when they exist |
| A reason to exist beyond search | Each is linked from the header's Locations panel and used by staff as the page they send renters for pickup instructions |
| A cap | No more than one new location page per week, each reviewed by a person. No bulk generation. No page for a place added "for coverage" |

The same rule protects category and model hubs: a hub is built only when it has cars, and its copy is written for that category or model, not templated with a swapped word.

## 4. The car page: what makes it rank and what keeps it from being thin

A car page is only as strong as its unique content. Two 2022 Corollas with the same paragraph are near-duplicates. The content template (layout in `01-public-site.md` section 4.3):

| Block | Unique to this car | Source | Minimum |
| --- | --- | --- | --- |
| H1 | Yes | Year, make, model, trim | "2022 Toyota Corolla LE rental in Toronto" |
| Photos | Yes | 12 or more of this exact car on the CarmaCars backdrop, with alt text | 10 approved photos |
| Intro description | Yes | Human-reviewed text from the listing pipeline, checked to be under 60% similar to any other listing | 120 to 220 words |
| Specifications table | Mostly | Year, make, model, trim, colour, body style, seats, doors, transmission, fuel, drivetrain, luggage, fuel economy or range | 10 rows |
| Features | Yes | The car's actual features | 6 to 14 |
| Rates table | Yes | Daily, weekend, weekly, monthly, kilometres included, overage, deposit, delivery and pickup fee, as text in the HTML (not only in the widget) | All rows |
| Live availability | Yes | Calendar and "next available" date in text | Rendered in the browser; a static "Check dates" fallback in the HTML |
| Who can rent it | Partly | Age rule for this car (18 to 20 allowed or not), licence classes, card, coverage options | 4 points |
| What is included | Shared (short) | Liability coverage, roadside assistance, kilometres | 3 points |
| Pickup and delivery | Yes | Home area, delivery options and fees, links to its location pages | 2 to 3 sentences |
| Reviews of this car | Yes | First-party reviews from completed rentals of this vehicle; then of the same model | Shown when they exist |
| FAQ | Yes | 4 to 8 questions about this model (trunk, child seats, winter tires, charging, highway range), answered from the listing and reviewed | 4 |
| Owner-style note | Yes | One or two sentences from the person who shot or reviewed the car ("The rear seats fold flat; we fit a bicycle in it") stored in `vehicle_listings.staff_note` **[new]** | Optional, encouraged |
| Similar cars | Links | Same class, same model, nearby price | 3 to 6 links |
| Breadcrumb | Links | | Always |

Shared boilerplate (policies, included items) is kept short on the page and linked to its own page, so the unique part dominates.

**Identical twins.** When two vehicles share year, make, model, trim and colour, both pages are published and bookable, but the second carries `rel="canonical"` to the first (`vehicle_listings.canonical_vehicle_id` **[new]**, set by the reviewer when the similarity check fires) and is left out of the sitemap. The model hub lists both with their own availability.

**Model hubs** (`/rent/toyota-corolla`) consolidate demand for a model: an original overview of renting that model with CarmaCars (written once per model, 200 to 400 words), every unit with price and next availability, all reviews for the model, the model's FAQ. They survive individual cars leaving the fleet, which makes them the durable ranking asset.

## 5. Titles, descriptions and headings

Built by `src/features/seo/meta.ts` from data; a per-page override exists (`seo_title`, `seo_description`). Titles under about 60 characters and descriptions 120 to 155 characters where possible; a test flags longer ones. One H1 per page.

| Page | Title pattern | Description pattern | H1 |
| --- | --- | --- | --- |
| Home | `Car Rental in Toronto: Request, Approve, Drive | CarmaCars` | `Rent well-kept cars from local owners in Toronto. Request with no card, get a confirmed offer, sign and pay online. Liability coverage included.` | `Car rental in Toronto, done properly` |
| Fleet | `Cars for Rent in Toronto: {count} Available | CarmaCars` | `Browse {count} cars for rent in the Toronto area, from ${min} a day. Real photos, real prices, live availability.` | `Cars for rent` |
| Car | `{Year} {Make} {Model} {Trim} Rental in {City} from ${daily}/day | CarmaCars` | `Rent this {colour} {year} {make} {model} in {home area}. {seats} seats, {transmission}, {km} km a day included. From ${daily} a day or ${weekly} a week. Request with no card.` | `{Year} {Make} {Model} {Trim} rental in {City}` |
| Model hub | `{Make} {Model} Rental in Toronto from ${min}/day | CarmaCars` | `{n} {Make} {Model} cars to rent in Toronto, from ${min} a day. See each car's photos, price and availability.` | `{Make} {Model} rental in Toronto` |
| Category | `{Category} Rental in Toronto from ${min}/day | CarmaCars` | Written per category | `{Category} rental in Toronto` |
| City | `Car Rental in {City}: Delivery from ${fee} | CarmaCars` | Written per city, naming the delivery method | `Car rental in {City}` |
| Neighbourhood | `Car Rental in {Neighbourhood}, Toronto | CarmaCars` | Written per place | `Car rental in {Neighbourhood}` |
| Airport | `Car Rental at {Airport name} ({CODE}) | CarmaCars` | Written per airport, describing exactly how the hand-over works | `Car rental at {Airport name}` |
| Need | For example `Car Rental With a G2 Licence in Toronto | CarmaCars` | States the actual rule | The question as asked |
| Guide | `{Guide title} | CarmaCars` | First 150 characters of the summary | Guide title |

Rules: the price in a title is the current daily rate and is rebuilt when the rate card changes; a title never promises something the page does not show (no "cheap", no "best", no "#1"); "CarmaCars" is always written that way; no em dashes (the lint covers metadata). Open Graph and Twitter card tags use the cover photo at 1200 by 630 and the same title and description.

## 6. Canonicals, parameters and the filtered fleet

| Case | Rule |
| --- | --- |
| Every indexable page | Self-referencing `rel="canonical"` with the absolute URL |
| `/cars` with any filter or date parameters | Canonical is `/cars`. The filtered views are for people, not for indexing; the indexable equivalents are the category, model and location pages |
| `/cars/[slug]?from=...&to=...` | Canonical is the clean car URL |
| Crawl control | `robots.txt` disallows URLs containing a query string on `/cars`. Google's guidance on faceted navigation is to prevent crawling of filter URLs when they do not need to be indexed, by `robots.txt` or by using URL fragments. Links in the HTML to car pages are always clean URLs; the chosen dates travel in `sessionStorage` and are appended only in the browser, so crawlers never see parameter URLs |
| Pagination | `/reviews?page=2` is self-canonical and indexable (it is the one parameter allowed); guides and fleet load more without new URLs |
| Trailing slashes, upper case, `www`, `http` | 301 to the canonical form |
| Tracking parameters (`utm_*`, `gclid`) | Ignored for rendering; canonical is the clean URL |
| Twins | Section 4 |
| Staging | `noindex` header on the whole staging host, plus basic authentication |

## 7. Structured data

JSON-LD in the page head, generated by typed builders in `src/features/seo/jsonld.ts` from the same data the page shows. Marked-up facts must be visible on the page.

### 7.1 What Google supports today, and what that means for us

| Feature | Status per Google's documentation | Use |
| --- | --- | --- |
| Local business | Supported. Name and address are required for the rich result; phone, hours, geo, URL and price range are recommended; "use the most specific LocalBusiness sub-type possible" | `AutoRental` (a `LocalBusiness` subtype in schema.org) on the home page, contact page and each location page |
| Organization | Supported | Merged into the `AutoRental` node: logo, legal name, contact points, `sameAs` |
| Breadcrumb | Supported | Every page below the home page |
| Product | Supported. "Product snippets" are for pages where people cannot buy directly; "merchant listings" are for pages where they can purchase. The documentation does not address rentals or vehicles | `Car` (a `Product` subtype) with an `Offer` on car pages. This is valid schema.org and describes the page truthfully. Whether Google shows a price or rating for a rental car page is its decision and is not promised anywhere in its documentation; we do not depend on it |
| Review snippet | Supported for a list of types including Product, Local business and Organization, with the rule: "If the entity that's being reviewed controls the reviews about itself, their pages that use LocalBusiness or any other type of Organization structured data are ineligible for star review feature." Reviews must be "readily available to users from the marked-up page", and "Don't aggregate reviews or ratings from other websites" | No `aggregateRating` or `review` on the `AutoRental` node, ever. First-party reviews of a specific car are marked up on that car's `Car` node, where the reviewed item is a product rather than the business. Google reviews are never copied into markup |
| Image metadata | Supported | `ImageObject` with `creator`, `creditText`, `copyrightNotice` for the cover photos |
| Vehicle listing | Removed. Google's documentation change log records in September 2025 the removal of documentation for vehicle listing structured data (with course info, estimated salary, learning video and special announcement) because these types are no longer shown in Search | Not used. It was for dealer inventory for sale in any case |
| FAQ | Removed. Google's FAQ structured data page now states the FAQ rich result is no longer shown in Search and the documentation was withdrawn | FAQ content stays on pages because renters need it. `FAQPage` markup is optional and earns no rich result; we include it only on `/faq` |
| Vacation rental, Carousel (beta) | Not applicable to car rental in Canada | Not used |

### 7.2 The business node (home, contact and location pages)

```json
{
  "@context": "https://schema.org",
  "@type": "AutoRental",
  "@id": "https://carmacars.ca/#business",
  "name": "CarmaCars",
  "legalName": "18122211 Canada Inc.",
  "url": "https://carmacars.ca/",
  "logo": "https://carmacars.ca/brand/carmacars-logo.png",
  "image": ["https://img.carmacars.ca/brand/fleet-1x1.jpg", "https://img.carmacars.ca/brand/fleet-4x3.jpg", "https://img.carmacars.ca/brand/fleet-16x9.jpg"],
  "telephone": "+1-000-000-0000",
  "email": "bookings@carmacars.ca",
  "priceRange": "$$",
  "address": {
    "@type": "PostalAddress",
    "streetAddress": "(the staffed address, when there is one)",
    "addressLocality": "Toronto",
    "addressRegion": "ON",
    "postalCode": "(postal code)",
    "addressCountry": "CA"
  },
  "geo": { "@type": "GeoCoordinates", "latitude": 43.65107, "longitude": -79.34702 },
  "openingHoursSpecification": [{
    "@type": "OpeningHoursSpecification",
    "dayOfWeek": ["Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"],
    "opens": "09:00", "closes": "18:00"
  }],
  "areaServed": [
    { "@type": "City", "name": "Toronto" },
    { "@type": "City", "name": "Mississauga" }
  ],
  "sameAs": ["(Google Business Profile URL)", "(Instagram)", "(Facebook)", "(TikTok)"]
}
```

Values come from `program_settings` and `content/company.ts`; the build fails on a placeholder. `areaServed` lists only cities with a published city page. If CarmaCars has no staffed address customers can visit, the street address is omitted here exactly as it is hidden on the Business Profile (section 14), and the page shows the service area instead.

### 7.3 The car node (car pages)

```json
{
  "@context": "https://schema.org",
  "@type": "Car",
  "@id": "https://carmacars.ca/cars/2022-toyota-corolla-le-grey-k3f9#car",
  "name": "2022 Toyota Corolla LE",
  "description": "(the listing description, as shown on the page)",
  "url": "https://carmacars.ca/cars/2022-toyota-corolla-le-grey-k3f9",
  "image": [
    "https://img.carmacars.ca/vehicles/(id)/2022-toyota-corolla-le-grey-front-left-1600.jpg",
    "https://img.carmacars.ca/vehicles/(id)/2022-toyota-corolla-le-grey-left-1600.jpg",
    "https://img.carmacars.ca/vehicles/(id)/2022-toyota-corolla-le-grey-dashboard-1600.jpg"
  ],
  "brand": { "@type": "Brand", "name": "Toyota" },
  "manufacturer": { "@type": "Organization", "name": "Toyota" },
  "model": "Corolla",
  "vehicleConfiguration": "LE",
  "vehicleModelDate": "2022",
  "bodyType": "Sedan",
  "color": "Grey",
  "fuelType": "Gasoline",
  "vehicleTransmission": "Automatic",
  "driveWheelConfiguration": "https://schema.org/FrontWheelDriveConfiguration",
  "seatingCapacity": 5,
  "numberOfDoors": 4,
  "itemCondition": "https://schema.org/UsedCondition",
  "offers": {
    "@type": "Offer",
    "url": "https://carmacars.ca/cars/2022-toyota-corolla-le-grey-k3f9",
    "businessFunction": "http://purl.org/goodrelations/v1#LeaseOut",
    "priceCurrency": "CAD",
    "price": "79.00",
    "priceSpecification": {
      "@type": "UnitPriceSpecification",
      "price": "79.00",
      "priceCurrency": "CAD",
      "unitCode": "DAY",
      "unitText": "per day",
      "valueAddedTaxIncluded": false
    },
    "availability": "https://schema.org/InStock",
    "eligibleDuration": { "@type": "QuantitativeValue", "minValue": 1, "maxValue": 30, "unitCode": "DAY" },
    "areaServed": { "@type": "City", "name": "Toronto" },
    "seller": { "@id": "https://carmacars.ca/#business" }
  },
  "aggregateRating": { "@type": "AggregateRating", "ratingValue": "4.8", "reviewCount": "12", "bestRating": "5", "worstRating": "1" },
  "review": [{
    "@type": "Review",
    "author": { "@type": "Person", "name": "Priya" },
    "datePublished": "2026-11-02",
    "reviewRating": { "@type": "Rating", "ratingValue": "5", "bestRating": "5", "worstRating": "1" },
    "reviewBody": "(the review text, as shown on the page)"
  }]
}
```

| Rule | Detail |
| --- | --- |
| Never included | VIN (`vehicleIdentificationNumber`), plate, owner, exact address of the car |
| Price | The current daily rate from the rate card, before HST, and the page shows the same number with "plus HST" |
| `availability` | `InStock` while the listing is published and taking requests; `OutOfStock` while paused. It describes the listing, not a particular date |
| Ratings | `aggregateRating` and `review` appear only when the page shows at least 3 published reviews of this vehicle (our threshold; Google requires the markup to match visible reviews). The figures are computed from `reviews` rows for that `vehicle_id` only. No ratings from other sites |
| Reviews integrity | Every published review comes from a completed booking (`reviews.booking_id`), is shown in full, includes negative ones, and is moderated only for personal information and abuse (`03-admin.md` section 14) |

### 7.4 Other nodes

| Page | Nodes |
| --- | --- |
| Every page | `WebSite` (name "CarmaCars", `url`), `BreadcrumbList` |
| Model, category, location pages | `ItemList` of the cars shown (name, URL, image, position), plus the business node on location pages with that page's `areaServed` |
| Guides | `Article` with `headline`, `datePublished`, `dateModified`, `author` (a named person at CarmaCars with a short bio page), `image` |
| `/faq` | `FAQPage` (no rich result expected) |
| Photos | `ImageObject` with `contentUrl`, `creator` (CarmaCars), `creditText`, `copyrightNotice`, `acquireLicensePage` (`/contact`) |

Validation: every template's JSON-LD is tested in CI against a JSON schema and with Google's Rich Results Test and the Schema Markup Validator before launch, then spot-checked monthly in Search Console's enhancement reports.

## 8. Image SEO for the photo pipeline output

| Topic | Rule |
| --- | --- |
| File names | `{year}-{make}-{model}-{trim}-{colour}-{angle}-{width}.{ext}`, for example `2022-toyota-corolla-le-grey-front-left-1600.jpg`. Written by the pipeline (`09-listing-pipeline.md` section 5.4). Stable: a re-shoot keeps the names and the cache is purged |
| Host | One image host (`img.carmacars.ca`), crawlable, not blocked by `robots.txt` |
| Formats and sizes | AVIF and WebP in `<picture>` with a JPEG fallback `src` (the JPEG is the URL listed in structured data and the sitemap). Widths 480 to 2400; `sizes` set per layout |
| Alt text | Factual and specific: "2022 Toyota Corolla LE in grey, front left view". Interior shots describe what is shown. No keyword lists. Stored in `vehicle_photos.alt_text`, editable in review |
| Dimensions | `width` and `height` on every image to prevent layout shift |
| Loading | The first gallery image: `fetchpriority="high"`, not lazy. All others `loading="lazy"`, `decoding="async"` |
| Captions | The gallery lightbox shows the angle name as visible text |
| Sitemap | Car page entries carry `image:image` tags for the published JPEG of each photo |
| Open Graph | Cover photo cropped to 1200 by 630 by the pipeline |
| Originality | Every photo is CarmaCars' own. No manufacturer stock images |
| Plates and people | Plates covered; no faces; this also avoids privacy removals |
| Licence metadata | `ImageObject` credit and copyright fields (section 7.4) |

## 9. Sitemaps

| File | Contents | `lastmod` |
| --- | --- | --- |
| `/sitemap.xml` | Index of the files below | |
| `/sitemap-pages.xml` | Home, fleet, company, need and legal pages | The content file's last commit date |
| `/sitemap-cars.xml` | Canonical car pages (twins excluded), with image entries | `vehicle_listings.updated_at`, updated only by real changes to content, photos or rates |
| `/sitemap-hubs.xml` | Model, make and category hubs | Latest change among their cars or their copy |
| `/sitemap-locations.xml` | City, neighbourhood and airport pages | Content date |
| `/sitemap-guides.xml` | Guides | `dateModified` |

Google's limits are 50 MB or 50,000 URLs per file, and it states it ignores `priority` and `changefreq` and uses `lastmod` only when it is "consistently and verifiably" accurate; so those two tags are omitted and `lastmod` is never bumped without a change. The sitemap is generated at build and on `revalidateTag('sitemap')`, referenced from `robots.txt`, and submitted in Search Console and Bing Webmaster Tools. A test asserts that every sitemap URL returns 200, is self-canonical and is not `noindex`.

## 10. Robots

```
User-agent: *
Disallow: /book
Disallow: /account
Disallow: /owner
Disallow: /investor
Disallow: /admin
Disallow: /va
Disallow: /field
Disallow: /go/
Disallow: /r/
Disallow: /unsubscribe
Disallow: /sign-in
Disallow: /sign-up
Disallow: /api/
Disallow: /cars?
Disallow: /cars/*?
Allow: /

Sitemap: https://carmacars.ca/sitemap.xml
```

Portal responses also send `X-Robots-Tag: noindex, nofollow`. Staging sends `noindex` on everything. The decision on AI crawlers (allow or disallow by user agent) is the owner's; the recommended default is to allow them, because being cited by assistants is a source of bookings and the public pages hold nothing private.

## 11. Cars that leave the fleet

A car page that vanishes wastes whatever it earned. Rules, applied by `unpublishListing` and stored in `listing_redirects` **[new]** (`from_path, to_path, status_code, reason, created_at`), served by the middleware:

| Situation | Response |
| --- | --- |
| Paused for service or repair, returning | Page stays (200). Shows "Not taking requests right now" and the expected date when a block has an end. Structured data `availability` becomes `OutOfStock`. Stays in the sitemap |
| Fully booked | Page stays (200) with its calendar |
| Exit notice given | Page stays until the Exit Date; the calendar shows the block after it |
| Exited, total loss or removed, and the model hub still has cars | 301 to `/rent/[make]-[model]`. The car's reviews remain on the hub as "reviews of this model" |
| Exited, and no car of that model remains but the category has cars | 301 to the category page |
| Exited, and nothing relevant remains | 410 Gone with a helpful page (search and similar cars). Never a redirect to the home page, which search engines treat as a soft 404 |
| The car returns to the fleet later | The redirect is removed and the same slug is reused (slugs are never recycled for a different car) |
| Slug changed for a correction | 301 from the old slug, kept permanently |
| A twin was the canonical and leaves | The remaining twin becomes canonical; the old URL 301s to it |

Redirects are single hop; a test follows every stored redirect and fails on a chain or a loop. The sitemap drops removed URLs at the same time.

## 12. Core Web Vitals budget on Cloudflare

Google's thresholds for "good", measured at the 75th percentile of real page loads on mobile and desktop: LCP within 2.5 seconds, INP 200 milliseconds or less, CLS 0.1 or less. Our budget is tighter so that there is margin.

| Metric | Budget (75th percentile, mobile) | How it is met |
| --- | --- | --- |
| LCP | 2.0 s | Static HTML from Cloudflare's cache; hero image preloaded with `fetchpriority="high"` at the right size (under 120 KB AVIF at 800 px); fonts self-hosted with `font-display: swap` and a size-adjusted fallback; no render-blocking third-party script |
| INP | 150 ms | Little JavaScript on public pages; the calendar, gallery lightbox and price panel are separate chunks loaded when visible or on interaction; no long tasks over 50 ms in the main bundle; filters update with `startTransition` |
| CLS | 0.05 | Width and height on all media; reserved space for the price panel, calendar and reviews; no banners injected above content; the cookie notice is an overlay at the bottom |
| Time to first byte | 200 ms for cached pages | Static generation plus cache; on-demand revalidation instead of per-request rendering |

| Asset budget per public route | Limit |
| --- | --- |
| HTML (compressed) | 40 KB |
| JavaScript (compressed, initial) | 170 KB |
| CSS (compressed) | 30 KB |
| Fonts | 2 files, 60 KB total |
| Requests before LCP | 12 |
| Third-party origins on public pages | 0 at load (Turnstile loads when a form is focused; Stripe only on the pay page) |
| Worker CPU per request | Under 5 ms median for cached pages (the plan limit is 10 ms) |

Enforcement: Lighthouse CI on five templates (home, fleet, car, location, guide) on every pull request with these budgets as failing thresholds; a bundle-size check; real-user Core Web Vitals from Cloudflare Web Analytics and Search Console reviewed weekly. Scroll effects use `transform` and `opacity` only and are disabled under reduced motion (`01-public-site.md` section 2).

## 13. Internal linking

| From | To | Rule |
| --- | --- | --- |
| Home | Top categories, Toronto city page, featured cars, owner page, how it works | In the HTML, not only in menus |
| Header and footer | Fleet, locations, long-term, categories, legal | Same on every page |
| Fleet | Every car (clean URLs), categories, model hubs | |
| Car | Its model hub, category, home-area location pages, 3 to 6 similar cars, relevant need pages (under 25 when `allows_18_to_20`), cancellation policy, how it works | Descriptive anchor text ("Toyota Corolla rentals", not "click here") |
| Model hub | Each unit, the make hub, the category, sibling models | |
| Category | Its cars, related categories, relevant guides | |
| City | Its neighbourhoods and airports, cars that serve it, guides about that city | |
| Neighbourhood, airport | Parent city, nearby places (real neighbours only), cars | |
| Guide | The cars, categories and locations it discusses; 2 to 4 contextual links | |
| Reviews | The car and model each review is about | |
| Breadcrumbs | Every level | |

A build-time report lists orphan pages (no internal link in), pages with fewer than 3 internal links in, and broken links. Zero orphans and zero broken links are release conditions (`15-test-plan.md` section 3).

## 14. Google Business Profile and other local profiles

| Item | Plan |
| --- | --- |
| Eligibility and type | Google's guidelines: a business that serves customers at their locations "should have one profile for the central office or location with a designated service area", and a service-area business "should hide your business address from customers". A rented mailing address where the business does not operate (a virtual office) "isn't eligible for a Business Profile". So: one profile. If CarmaCars has a staffed location customers can come to during stated hours, it is a storefront with a service area (hybrid). If it only delivers and meets customers, it is a service-area business with the address hidden. Which applies is an open question for the owner |
| One profile only | "Do not create more than one page for each location of your business." No profiles for suburbs, airports or meeting points |
| Name | Exactly "CarmaCars". The guidelines forbid adding service or location words to the name |
| Category | Primary: Car rental agency. Add a second only if it is truly a core business; "use as few categories as possible" |
| Service area | The cities actually served, matching the city pages |
| Details | Hours matching `program_settings.opening_hours`, phone, website with a `utm_source=gbp` parameter (canonical handles it), booking link to `/cars`, services (delivery, long-term rental, insurance replacement), attributes, the opening date (October 15, 2026) |
| Photos | The fleet on the brand backdrop, real handovers (with consent), the team. Add 3 to 5 a month |
| Posts | One a week: a new car, a guide, a seasonal note |
| Questions and messages | Seed nothing fake. Answer every real question within a day |
| Verification | Start it before launch; video verification can take days to weeks |
| Other profiles | Bing Places, Apple Business Connect: same name, address or service area, phone, hours |

## 15. Reviews strategy

| Rule | Detail |
| --- | --- |
| Ask everyone, the same way | Every renter with a completed rental gets `renter_review_request` two days after the booking closes. The request does not depend on how the rental went. The email template's trigger holds the request back while a booking has an open incident, dispute or unpaid balance; this blueprint treats that as a delay until the matter is closed, never as an exclusion, because leaving unhappy customers out would be selective solicitation. Google's policy forbids businesses to "discourage or prohibit negative reviews, or selectively solicit positive reviews" |
| No incentives | Nothing is offered for a review: no discount, credit or gift. Google's policy prohibits offering "incentives, such as payment, discounts, free goods and/or services, in exchange for posting any review". The come-back discount at one week goes to every eligible renter whether or not they reviewed, in a separate email that does not mention reviews |
| Two destinations | The request leads to CarmaCars' own review form (which feeds car pages). After submitting, the renter is offered a link to the Google review form. Neither is gated by the rating given |
| First-party reviews | Verified by booking, published in full including critical ones, with a public reply from CarmaCars. Moderation removes only personal information and abuse |
| Replies | Every Google and site review gets a reply within 2 business days, specific to the rental. A critical review gets a factual, courteous reply and an offer to talk |
| Never | Staff or owners reviewing the business; reviews written on a customer's behalf; asking at the handover on a staff device; buying reviews; copying Google reviews into site markup |
| Target | 25 Google reviews and 40 site reviews in the first 90 days, which at about 50 rentals a month needs a response rate near 30%. Review count and recency are tracked weekly |
| Use on site | Car pages (per vehicle), model hubs (per model), `/reviews` (all), home (three recent). The business node carries no rating markup (section 7.1) |

## 16. Local citations and link earning

**Citations** (consistent name, address or service area, phone, website; a spreadsheet records each login and status):

| Priority | Where |
| --- | --- |
| Week 1 | Google Business Profile, Bing Places, Apple Business Connect, Facebook page, Instagram, the Turo host profile (linking to the site where allowed) |
| Weeks 2 to 4 | Yelp Canada, Yellow Pages Canada (yp.ca), 411.ca, Better Business Bureau profile, Foursquare, the local board of trade or chamber of commerce, the franchisor's location or partner page if one exists |
| Month 2 | Kijiji Autos and other classified sites used for listings (procedure 17), each linking to the car page; neighbourhood business improvement area directories where a base exists |

**Links worth having** are earned by being useful or newsworthy, not bought. Google's spam policies treat bought links and link schemes as violations.

| Source | Tactic | Effort |
| --- | --- | --- |
| Partners | Body shops and collision centres (for insurance replacement), independent insurance brokers, hotels and short-stay hosts, moving companies, immigration settlement agencies, university international student offices: a "preferred local rental" page on their site in return for a real service arrangement | Outreach by the CS VA: 10 contacts a week |
| The owner programme | Local business and personal finance writers: "what a car earns on a managed rental fleet" with real, anonymized numbers from the platform after 3 months | One story |
| Data | Quarterly short reports from our own data: most requested cars, cost of 407 ETR for a week's rental, average rental length by season. Sent to local news and car blogs | 4 a year |
| Guides | The guides in section 17 answer questions people link to (tolls, G2 rules, winter tires) | Ongoing |
| Community | Sponsor one local event or team per quarter where the audience matches; supplier and vendor pages (tracker supplier, detailing supplier) | Small budget |
| Journalists | Answer requests for comment on car sharing, rental prices and insurance | As they come |
| Unlinked mentions | Monthly search for "CarmaCars" and ask for a link where the name appears without one | 30 minutes a month |

Not done: paid links, link exchanges at scale, private blog networks, directory spam, guest posts on unrelated sites, widgets with embedded links.

## 17. Content plan for the first 90 days

Every piece is written or fully edited by a person who knows the operation, carries the author's name, and is dated. Machine drafts are allowed as a starting point, never published unedited (`09-listing-pipeline.md` section 5.3 has the same rule for listings).

| When | Pages | Notes |
| --- | --- | --- |
| Before launch | Home, fleet, every car page complete to the section 4 template, `/car-rental/toronto`, 1 or 2 neighbourhood pages where cars are based, `/how-it-works`, `/faq`, `/list-your-car`, `/long-term-car-rental`, `/insurance-replacement`, policies, `/about` with real names and photos | The minimum credible site |
| Weeks 1 to 2 | Model hubs for every model in the fleet; category pages with 2 or more cars; guide 1: "How renting with CarmaCars works: request, offer, sign, pay"; guide 2: "407 ETR tolls in a rental car: what you pay and how it is billed" | |
| Weeks 3 to 4 | `/car-rental/under-25` and `/car-rental/g2-licence` (the actual rules and fees); guide 3: "Do I need extra insurance to rent a car in Ontario? OPCF 27, credit card coverage and your options" (reviewed by the lawyer or broker; no provider named); first airport page only if the meeting procedure is confirmed | |
| Weeks 5 to 6 | Second city page if delivery there is live; guide 4: "Monthly car rental in Toronto: costs, kilometres and renewals"; guide 5: "Winter driving in a rental: tires, fees and what to check" (timely for November) | |
| Weeks 7 to 8 | Guide 6: "What happens if a rental car is damaged: deductible, claims and timelines"; guide 7 for owners: "What it costs to put your car on a rental fleet in Ontario: registration options and fees" (uses the six situations); refresh car pages with first reviews | |
| Weeks 9 to 10 | Guide 8: "Pickup and return at Pearson: how delivery works" (if offered); a comparison page written fairly: "CarmaCars or a traditional rental counter: what is different"; third neighbourhood page if a base exists | |
| Weeks 11 to 13 | First data note from platform numbers; guide 9: "Renting a Tesla in Toronto: charging, range and costs" (if an EV is in the fleet); review and rewrite the weakest five pages by Search Console data | |
| Ongoing | 2 guides a month; each new car's page within 2 business days of enrollment; every page reviewed at least every 6 months, with `dateModified` changed only when content changes | |

Keyword research is done from Search Console queries once data exists (about 4 weeks after launch) and from the questions renters actually ask CS (tagged in `leads` and `messages`), not from volume tools alone.

## 18. Measurement

| Tool | Cost | Used for |
| --- | --- | --- |
| Google Search Console (domain property, verified by DNS in Cloudflare) | Free | Queries, pages, clicks, average position, index coverage, sitemaps, Core Web Vitals, structured data reports, manual actions |
| Bing Webmaster Tools | Free | The same for Bing, which also feeds other assistants and search products |
| Cloudflare Web Analytics | Free on all Cloudflare plans; Cloudflare describes it as privacy-first analytics | Visits, top pages, referrers, countries, and real-user Core Web Vitals. A test in `15-test-plan.md` asserts that the public site sets no analytics cookie and stores nothing in the browser for analytics; if that ever changes, the cookie notice becomes a consent choice |
| The platform's own data | Free | Conversions: `bookings.request_details` **[new]** stores the landing path, referrer and `utm_*` values captured in `sessionStorage` on arrival. Reports: requests, offers accepted and confirmed bookings by landing page type, by car, by source |
| Lighthouse CI | Free | Lab performance on every pull request |
| Business Profile insights | Free | Searches, calls, direction requests, website clicks |

| KPI | Weekly | Target at 90 days |
| --- | --- | --- |
| Indexed pages against sitemap URLs | Yes | 95% or more of canonical pages indexed |
| Impressions and clicks (non-brand) | Yes | A rising trend; no fixed number is honest before data exists |
| Car pages with at least one impression | Yes | 90% |
| Queries where a car or model page ranks in the top 10 | Yes | Most "[year] [make] [model] rental Toronto" queries for cars in the fleet |
| Core Web Vitals "good" URLs | Yes | 100% of public templates |
| Reviews: Google and site, count and average | Yes | 25 and 40 |
| Requests from organic search; share of confirmed bookings | Yes | Reported, with cost per booking compared with paid channels |
| Referring domains | Monthly | 20 real, relevant domains |
| Manual actions, security issues | Yes | None |

A monthly one-page SEO report is added to `/admin/reports` (Growth tab) from Search Console exports and the platform's conversion data.

## 19. What determines ranking that code cannot deliver, and how long it realistically takes

| Factor | Why code cannot supply it | Who supplies it |
| --- | --- | --- |
| Authority: links and mentions from other sites | Earned over time by reputation, partnerships and coverage | Owner, CS and Sales outreach; section 16 |
| Reviews: number, quality, recency | Come from real customers after real rentals | Operations quality; the review request flow only asks |
| Proximity and local prominence | Local results weigh how close the business is to the searcher and how well known it is. A new company with one base is near few searchers | Physical bases; a verified Business Profile; time |
| Inventory | A page ranks for a car only if the car exists. Breadth of fleet is breadth of search coverage | Owner recruitment |
| Real experience in content | Guides and location pages need facts only the operator knows | Staff who do the handovers |
| Brand searches | People searching "CarmaCars" is itself a strong signal and comes from marketing, service and word of mouth | Marketing |
| Competitors | Enterprise, Hertz, Avis, Budget and their sister brands, Turo, and aggregators such as Kayak and Expedia hold the head terms with enormous link authority and national footprints | Cannot be changed; can be worked around with specificity |
| Google's own decisions | Which rich results appear, how often the site is crawled, and ranking changes in core updates are outside anyone's control | Nobody |
| Time | New domains are crawled and trusted gradually | Patience |

**Realistic timeline** (our judgment, assuming the plan is executed and the service is good):

| Period | What to expect |
| --- | --- |
| Weeks 1 to 4 | Pages indexed. Ranking for the brand name. First impressions on exact car and model searches |
| Months 2 to 3 | Top 10 for many specific searches: "[year] [make] [model] rental Toronto", "[model] rental [neighbourhood]", need pages with little competition. First organic requests |
| Months 3 to 6 | Model hubs, need pages and neighbourhood pages gain positions as reviews and links arrive. The Business Profile appears in the local pack for searches near the base |
| Months 6 to 12 | Competitive for "[category] rental Toronto" and for city pages in served suburbs, if links and reviews have kept growing. Local pack presence widens with more bases |
| Months 12 to 24 | A realistic shot at page one for "car rental Toronto" variations alongside the national brands, not ahead of all of them |
| "Top-ranking car rental company in Canada" | Not achievable by a website. It requires operating in the other major cities (with city pages earned by real operations there), national brand awareness, years of links and reviews, and French content for Quebec. The platform is built so that each new city adds its pages cleanly; the ranking follows the business |

What code does deliver, and this build includes all of it: fast, crawlable, unique, well-structured pages for every car; correct technical signals (canonicals, sitemaps, structured data, redirects); a review engine that follows the rules; measurement; and no technical reason for a page to underperform.

## 20. Risks and safeguards

| Risk | Safeguard |
| --- | --- |
| Thin or duplicate car pages as the fleet grows with similar cars | Similarity check, twin canonicals, model hubs |
| Doorway pages | Section 3 build checks; one-page-a-week cap; a person signs off each |
| Machine-sounding copy | Copy lint, banned phrases, mandatory human edit, named authors on guides |
| Self-serving review markup | Builders cannot attach ratings to the business node (a unit test asserts it) |
| Losing equity when cars leave | Section 11 redirects |
| A redesign or route change breaking URLs | URLs in section 2 are a contract; any change needs a redirect in the same pull request, and a test compares the sitemap with the previous release |
| Staging indexed | `noindex` and authentication on staging |
| Parameter crawl waste | Section 6 |
| Price in titles going stale | Titles rebuild on rate change |
| Policy changes at Google | Section 7.1 is re-checked every quarter against the documentation; the change log is recorded in this file |

## 21. Database additions needed

| Addition | Purpose |
| --- | --- |
| `vehicle_listings`: `seo_title`, `seo_description`, `specs`, `faq`, `home_area`, `staff_note`, `canonical_vehicle_id`, `updated_at` maintained only on content changes | Sections 4, 5, 9 |
| `listing_redirects (from_path primary key, to_path, status_code, reason, created_by, created_at)`, read at build and by the middleware through a server-side lookup (so the anonymous role still selects from one view only) | Section 11 |
| `app.public_reviews()` `[0016]` returns published reviews for a vehicle with the first name and month; add an optional model filter (or a view) for model hubs | Sections 4, 7.3, 15 |
| View `public_model_hubs` (make, model, count, minimum daily rate, next availability) | Model hub pages at build |
| `bookings.request_details` keys `landing_path`, `referrer`, `utm` | Section 18 |
| `reviews.google_prompt_clicked_at` | Measuring the second step of the review flow |

## 22. Sources

Read on October 7, 2026.

- Google Search Central, spam policies (doorway abuse, scaled content abuse): https://developers.google.com/search/docs/essentials/spam-policies
- Google Search Central, creating helpful, reliable, people-first content: https://developers.google.com/search/docs/fundamentals/creating-helpful-content
- Google Search Central, structured data search gallery (supported features): https://developers.google.com/search/docs/appearance/structured-data/search-gallery
- Google Search Central, review snippet structured data (self-serving reviews rule; visibility; no aggregation from other sites): https://developers.google.com/search/docs/appearance/structured-data/review-snippet
- Google Search Central, local business structured data: https://developers.google.com/search/docs/appearance/structured-data/local-business
- Google Search Central, product structured data (product snippets and merchant listings): https://developers.google.com/search/docs/appearance/structured-data/product
- Google Search Central, vehicle listing structured data page and documentation change log (removal recorded September 2025): https://developers.google.com/search/docs/appearance/structured-data/vehicle-listing
- Google Search Central, FAQ structured data page (FAQ rich result no longer shown; documentation removed): https://developers.google.com/search/docs/appearance/structured-data/faqpage
- Google Search Central, managing crawling of faceted navigation URLs: https://developers.google.com/search/docs/crawling-indexing/crawling-managing-faceted-navigation
- Google Search Central, build and submit a sitemap: https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap
- web.dev, Web Vitals (thresholds and the 75th percentile): https://web.dev/articles/vitals
- Google Business Profile, guidelines for representing your business: https://support.google.com/business/answer/3038177
- Google Maps user-contributed content policy, fake engagement (review incentives; selective solicitation): https://support.google.com/contributionpolicy/answer/7400114
- Cloudflare Web Analytics documentation: https://developers.cloudflare.com/web-analytics/
- schema.org types used: https://schema.org/AutoRental, https://schema.org/Car, https://schema.org/Offer, https://schema.org/UnitPriceSpecification

Not verified in this research and therefore stated as recommendations only: the exact timing of Business Profile verification; airport rules for off-airport rental hand-overs; whether Google currently shows price or rating results for rental car pages marked up as `Car`.
