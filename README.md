# Search copy batches (migration 0133)

The search text of the website (landing pages, car pages, guides) is written by a daily scheduled Claude session, not by Workers AI. The website's own Workers AI writer is off by default (Program settings: "Search copy: the website writes it with Workers AI", `seo_ai_writer_enabled`); turning it on again makes it write within the background share of the day's free allowance.

Order of precedence for a page's text: hand-written (this batch, source `claude-batch`, or Workers AI, source `ai`, or staff edits) comes before the writing kit's text (source `kit`), which comes before the old template. The queue never offers a page whose text is `claude-batch` or `ai` and still matches its facts; a field a person locked is never replaced.

## The flow

1. **`seo-queue`** (`.github/workflows/seo-queue.yml`): every day at 09:10 UTC (and on demand, input `limit`, default 500) it reads the next pages that need text from the database (`app.seo_batch_queue`, through `scripts/deploy/sb.sh`, so it works on the hosted project and on the company's own server) and force-pushes them as **`seo/queue/latest.json`** to the branch **`seo-queue`** (this file is its README). Main is never touched.
2. **The writer** (the scheduled Claude session) reads `seo/queue/latest.json` on the branch `seo-queue`, writes each item, and commits one or more batch files **`seo/batches/<date>-<name>.json`** to main.
3. **`seo-import`** (`.github/workflows/seo-import.yml`): on a push to main that adds or changes `seo/batches/**.json` (or on demand, input `files`), it reads the live facts of every item (`app.seo_batch_context`), checks each with the website's own checks (`web/src/features/seo/batch.ts`, the same functions the Workers AI writer's answers pass in `web/src/features/seo/worker.ts`), publishes the items that pass through `app.seo_batch_publish` (source `claude-batch`), rebuilds the public pages (`/api/jobs/public-rebuild`, as after a fleet change) and prints notices: **published** (count and addresses) and each **rejected** item with its reasons. The database queues the changed addresses for IndexNow; the next search job tick sends them.

"Needs text", most valuable first: landing pages (places first, then uses), then the car pages of published cars (the ones staff asked for first, then those with template or kit text), then the guides. A page needs text when it was never written by a person or a model, was written before its facts changed, or is waiting (pending or failed).

## Input: `seo/queue/latest.json`

```json
{
  "version": "seo-queue-v1",
  "generated_at": "2026-10-25T09:10:12Z",
  "count": 500,
  "waiting": { "pages": 31, "cars": 62, "articles": 8 },
  "rules": {
    "banned": ["phrases staff banned in Program settings"],
    "similarity_max": 0.5,
    "limits": { "seo_title": [25, 60], "meta_description": [90, 155], "h1": [20, 70], "intro_words": [8, 40], "...": "every length of copy.ts LIMITS" },
    "house": ["No em dash or en dash anywhere.", "Write CarmaCars exactly so; ...", "..."]
  },
  "output": { "file": "seo/batches/<date>-<name>.json", "shape": "..." },
  "items": [
    {
      "kind": "page",
      "id": "mississauga",
      "url": "/car-rental/mississauga",
      "priority": 1,
      "page_type": "location",
      "name": "Mississauga",
      "facts": { "highways": ["401", "403"], "drive_minutes": "25 to 40" },
      "brief": null,
      "locked": [],
      "current": { "seo_title": "...", "intro": "...", "sections": [], "faq": [] },
      "current_source": "seed",
      "write": ["seo_title", "meta_description", "h1", "intro", "sections", "faq"],
      "word_target": "intro 60 to 130 words; 3 to 4 sections of 60 to 180 words; 4 to 6 questions",
      "avoid": [],
      "instructions": { "system": "the Workers AI writer's system prompt", "prompt": "the Workers AI writer's prompt for this page, with the facts" },
      "output_schema": { "type": "object", "properties": { "...": "..." } },
      "prompt_version": "landing-v1"
    }
  ]
}
```

Per kind:

| kind | id | url | facts / brief | write | output_schema |
| --- | --- | --- | --- | --- | --- |
| `page` | the landing page's slug | `/car-rental/<slug>` | `facts` (the place or use, its highways, delivery, counts) | `seo_title`, `meta_description`, `h1`, `intro`, `sections`, `faq` | `PAGE_COPY_SCHEMA` |
| `car` | the car's id (uuid) | `/cars/<slug>` (null before the listing has one) | `facts` (car, equipment known and possible, prices, place, rules, included, photos, brand) | `intro`, `highlights`, `good_for`, `faq`, `alt_texts` (the site fills `seo_title`, `meta_description`, `h1`, `pickup_delivery`, `included`, `requirements` itself) | `CAR_COPY_SCHEMA` |
| `article` | the guide's slug | `/guides/<slug>` | `brief`, and `current` (title, description, body_md, faq) | `title`, `description`, `body_md`, `faq` | `ARTICLE_SCHEMA` |

`avoid` (cars): the introductions other cars of the same model already use; write differently.

## Output: `seo/batches/<date>-<name>.json`

```json
{
  "batch": "2026-10-25-morning",
  "items": [
    {
      "kind": "page",
      "id": "mississauga",
      "copy": {
        "seo_title": "Car Rental in Mississauga | CarmaCars",
        "meta_description": "Rent a car in Mississauga with delivery to your address or pickup from us. Request with no payment up front.",
        "h1": "Car rental in Mississauga",
        "intro": "...",
        "sections": [{ "heading": "Delivery in Mississauga", "body": "..." }, { "heading": "Roads and parking", "body": "..." }],
        "faq": [{ "question": "Do you deliver to Square One?", "answer": "..." }]
      }
    },
    {
      "kind": "car",
      "id": "00262c25-a4be-4e2c-b1ab-f2e9f8657c9a",
      "copy": {
        "intro": "A big boot, a high seat and all-wheel drive for whatever February brings.",
        "highlights": ["Backup camera", "Bluetooth", "Heated front seats", "Apple CarPlay and Android Auto", "Cruise control", "Air conditioning"],
        "good_for": ["Airport runs with luggage", "Winter trips north"],
        "faq": [{ "question": "How many people fit?", "answer": "Five adults." }],
        "alt_texts": { "front_left": "BMW X6 M in black, front left view" }
      }
    },
    {
      "kind": "article",
      "id": "winter-driving-in-toronto",
      "title": "Winter driving around Toronto, step by step",
      "description": "...",
      "body_md": "## Before you go\n\n...",
      "faq": [{ "question": "Do I need winter tires?", "answer": "..." }]
    }
  ]
}
```

- An item names its page by `id` (with `kind`) or by `url` (`/car-rental/<slug>`, `/cars/<slug>`, `/guides/<slug>`).
- A bare array of items is accepted too.
- `prompt_version` (optional) is stored with the text.
- The same page twice in one batch: the first is used, the second rejected.

## The checks (an item is published only when it passes all of them)

The website's own checks (`web/src/features/seo/copy.ts`, as for the Workers AI writer):
- lengths of every field (titles, descriptions, headings, intro words, sections, questions, alt texts);
- the house style: no em dash or en dash, no exclamation marks, no AI-sounding or banned words, CarmaCars spelled exactly so, never a numbered or legal company, never insurance presented as bought from CarmaCars (only "the Protection Plan");
- claims only from the facts: equipment, fuel economy, range, power, safety ratings, condition, price promises ("unlimited kilometres", "no deposit", "lowest price");
- numbers only from the facts; no typed prices on landing pages; articles write CarmaCars fees only as the `{{tokens}}` the article already uses;
- a car's highlights copied from its equipment lists; its intro does not say where the car is kept and does not repeat another car's;
- never the VIN, the plate, the odometer or the owner.

Added for the batch (`web/src/features/seo/batch.ts`):
- no promise of a service the facts do not state (guarantees, warranties, same-day service, 24/7, certified technicians, OEM parts, "we repair", free pickup, towing, estimates, loaners, inspections, car washes, money back);
- every page unlike the others: a landing page unlike every other landing page (35% of five-word sequences at most), a guide unlike every other guide, a car unlike the other cars of its model (the Program setting) and every other car (80%), and each item unlike the earlier items of the same batch.

The database checks a car's copy again when it is published (`app.car_copy_apply`); a refusal there is reported as rejected too.
