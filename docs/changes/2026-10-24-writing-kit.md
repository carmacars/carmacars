# The writing kit: rich, true, varied text on every programmatic page, with no model at render time (October 24, 2026)

No migration (SCHEMA_MARKER unchanged). The owner: "do the writing kit, no reason not to and why waste ai usage".

## What changed

Every programmatic page now carries 250 to 600 words of hand-written text, chosen and filled from the page's own facts
on the Worker in about a quarter of a millisecond. No text is generated at render time, nothing is written to the
database, and the same address always shows the same words.

- **The library** (`web/src/features/kit/lib/`): 2,569 hand-written variants (31,099 words) in 196 banks, one bank per
  page type and slot: intro, why rent here, local context, delivery and pickup, the honest words for places we do not
  serve, day trips from Toronto, what the car is like, the specs in plain words, who it suits, trips, renting it from
  us, how booking works, requirements, the service explained, what to ask the shop, aftercare, closing, and questions
  that are true on every page of a type. A variant can depend on the page's facts (electric or gas, SUV, sedan, truck
  or van, luxury or mainstream, all-wheel drive, a winter region, an airport we hand cars over at, the Toronto area,
  elsewhere in Ontario, another province, the United States or Mexico, the term's family) and names only facts the
  page has: `{place}`, `{km}`, `{deliveryFrom}`, `{airport}`, `{nearbyList}`, `{make}`, `{model}`, `{year}`, `{trim}`,
  `{body}`, `{seats}`, `{engine}`, `{drive}`, `{l100}`, `{kwh100}`, `{range}`, `{cargoL}`, `{cost100}`, `{term}`,
  `{job}`, `{fromDaily}` (only from real cars, never the sample cars) and the site's settings (`{{maxDays}}`,
  `{{minAge}}`, `{{licence}}` ...). There is no horsepower: no free source publishes it, so no sentence names it.
- **The rules every variant follows**: plain Canadian English, no dashes, CarmaCars spelled so and never the numbered
  company, no reviews, ratings, awards or availability claims, no price that is not a real rate. The Protection Plan is
  never called insurance or coverage and its provider is never named. A place beyond our delivery area is told plainly
  that CarmaCars is in Toronto and what we can do from there. The mechanical work we arrange (0121) is always "we
  arrange it with a trusted shop, and rent you a car meanwhile": never our work, no price, no promise, no word of
  insurance, no questions block. Buying help always says we do not sell, lend or lease.
- **The engine** (`engine.ts`): picks one variant per slot with a stable hash of the address (FNV-1a), skips a variant
  whose facts are missing, drops an optional part (`[...]`) whose facts are missing, never repeats a sentence or a
  topic on a page (`#topic`), and starts each use of a bank at its own hashed place so two pages never share runs of a
  list. Sections of a group may swap places by the hash. A page over its range loses its lowest priority sections
  first. Banks are compiled once per Worker isolate.
- **Facts and plans** (`facts.ts`, `pages.ts`, `plans.ts`): the facts and tags of a page from its own read (the hub of
  0095, the vehicle pages and twins of 0097), and each page type's sections, slots, questions and word range: hub-rental
  350 to 600, the vehicle trim pages 400 to 600, the others 250 to 550.
- **Precedence**: text written for the page (`written` on the page's read, which seo-import's daily batch will fill)
  wins over the kit; the kit replaces the old template's body text; the template's short factual lead stays in the head
  of the page and its questions come first, the kit's after (eight at most). The hub's old "Around" block is shown only
  when the kit has no local section.
- **Wired into every programmatic page type**: the place pages of every family (`HubPage.tsx`: `/car-rental/<place>`,
  `/car-rental/<term>/<place>`, `/buy/<sale term>/<place>`, `/detailing/...`, `/body-shop/...`, the mechanical work we
  arrange), the vehicle pages (`views.tsx`: make, model, year, trim; `deep.tsx`: a trim in a place or a colour) and
  their twins (`twin.tsx`: `/buy/...` and `/t/<term>/...`, seeded by the twin's own address so a twin never reads like
  its `/cars` page). `KitText.tsx` renders it as plain headings and paragraphs (`data-testid="kit-text"`,
  `data-kit-source`).

## Quality gates (`web/src/features/kit/kit.test.ts`)

On 10,000 sampled addresses across all 17 page types:

- no slot left unfilled, no dash, no word of the AI list (`features/seo/copy.ts`), no equipment, condition, price
  promise or praise claim, the brand right, never the Protection Plan beside insurance;
- honesty by page type (far places, the mechanical work we arrange, buying help, financing and leasing, no daily price
  without a real rate);
- word counts within each type's range (none over, at most 5% under); Flesch reading ease 50 or more (73 to 86 by type);
  no sentence over 40 words;
- near-duplicates by MinHash over five-word shingles (128 hashes, LSH bands): below 1% at a similarity of 0.5 or more.
  Measured: 0 of 10,000 (0.00%); highest pair 0.41; random pairs of the same type 0.05; neighbours (the same term, the
  next place) 0.06;
- CPU time (not wall time; the test machine is shared): mean 0.24 ms a page warm, p99 0.9 ms; the first page of a cold
  isolate about 10 to 20 ms (compiling the banks once).

The SEO audit (`tests/lint/seo-audit.mjs`) now also fails a sampled programmatic page with fewer than 200 words of kit text.

## Page counts

How many pages the site can render, from the routes and the database functions (0095, 0097, 0115, 0121, 0123):

- **Place pages**: every active place (not a landmark) times every active term: 323 terms (169 with their own pages and
  154 synonyms that render with their term's page as canonical): renting 128, buying help 41, detailing 42, body shop
  112 (77 of them the mechanical work we arrange). So 323 x P.
- **Vehicle pages**: 170 trees (`/cars`, `/buy` and the 168 terms of `app.vpage_terms`), each with its level pages B
  (makes, models, years, trims), and for each trim T its place pages, place and colour pages (12 colours) and colour
  pages: `170 x (B + 13 x T x P + 12 x T)`. With the catalog of the vehicle pages' dry run (B = 18,341, T = 2,490):
  `170 x (48,221 + 32,370 x P)`.

| Places loaded (P) | Place pages | Vehicle pages | Listed in the sitemaps | Sitemap files | Index files |
| --- | --- | --- | --- | --- | --- |
| 10,000 (Ontario and the GTA neighbourhoods) | 3,230,000 | 55,037,197,570 | about 55.04 billion (1,690,000 place pages and every vehicle page) | about 1,174,560 | 24 |
| 100,000 | 32,300,000 | 550,298,197,570 | about 550.3 billion | about 11.08 million | 222 |
| 1,000,000 (Canada, the US and Mexico) | 323,000,000 | 5,502,908,197,570 | about 5.5 trillion | about 110.14 million | 2,203 |

What the sitemaps list: the place files list each of the 169 terms with their own pages (synonyms never) over every
place in an enabled region (the quality gate is off by default; on, places beyond the delivery area drop out except
countries, provinces and areas), in files of 25,000 places by id, at most 49,000 place files in the index; the vehicle
files list every indexed page of every tree (all switches on and `vpage_index_mode` "all" by default, so every vehicle
page), at most 50,000 addresses a file (a tier file holds 3,846 trim and place pairs of 13 addresses), about 433 level
files and `ceil(T x P / 3,846)` tier files per tree; an index file holds 50,000 sitemaps. So the sitemaps list about
52% of the place pages (169 of 323 terms) and essentially all the vehicle pages. On the local stack (40 places, 120
trims, 12 colours): 63,840 pages per tree, 10,852,800 vehicle pages, 37 level files and 2 tier files per tree (6,630
vehicle files) and 169 place files.

## Tests

`kit.test.ts` (above); the unit suite, typecheck, lint, the text check and the change guides check; end to end:
seo-coverage, local-seo, vehicle-pages and seo (one worker, production build); the SEO audit.

## Guides

No guide change: the writing kit changes the words of the public pages only; no screen, setting or step of any portal changes.
