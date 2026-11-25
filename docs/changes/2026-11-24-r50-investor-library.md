# Investor Documents library and What's new for investors (Release 50: 4300, 4301)

Migrations `4300_r50_investor_library.sql` and `4301_r50_investor_library_notices.sql`, generator `supabase/seed/4301_gen_catalogue.mjs`, email `emails/src/emails/investor_document_updated.mjs`.

## What it does

- **Library**: Documents > **Business documents** in the investor portal. Sections from `investor_library_kinds`: Business plan, Financial forecast, Pitch deck, Feature decks, and any an Admin adds. Each item (`investor_library_items`) shows its title, section, version and the date it was updated; investors see the latest version only.
- **Versions**: `investor_library_versions` keeps every upload or link; a replacement is a new version, never an overwrite. A file is a PDF (checked by its first bytes, under 50 MB) in the private `documents` bucket under `investor-library/<item>/<uuid>.pdf`; a deck may be an https link.
- **Admin**: Admin > Investors > **Documents** (`/admin/investors/documents`): add a document (section, title, PDF or link), **Replace** with a new version, **Hide from investors** / **Show to investors**, and the version history with each version's download. Investors only; no staff role reads investor records, so there is no staff portal copy.
- **Files**: `/investor/documents/library/<item>` and `/admin/investors/documents/<version>`: the database checks the signed-in investor (`app.investor_of`) or Admin, then the server makes a 5-minute signed link (`no-store`, `no-referrer`).
- **Notice**: `investor_document_updated` (email from hello@, replies to investors@, CarmaCars branding) to every active investor once per version, with the portal's notice; push on the `documents` topic; never a text.
- **What's new**: `WhatsNewFeed` reads `src/generated/whats-new.json` (built by `scripts/whats-new.mjs` from `docs/releases/rNN.md`, `## For investors`); a release with no investor section shows its summary. On the investor dashboard (latest three) and at the top of Updates (all). Items that hit the investor deny list (another business, vendors, costs) are never shown.
- **Guide me**: the step file `investor-library`. `flows.ts` now lists every step file (the portal workflows of 4100 were not listed, so only the eight staff workflows could start); a unit test keeps it so.
- **Separation**: CarmaCars documents only; nothing here names another business.
- **Security**: three new tables with row-level security, `admin_all` and the audit trigger; every function security definer with `search_path = public, app, pg_temp`, the server role only; through the door (`investor_read library`, `library_file`; `admin_read investor_library`, `investor_library_file`; `admin_do investor_library_save`, `investor_library_archive`).

## Guides

No guide change: the new tab is walked by its Guide me step file (`investor-library`); the investor guide's text is written with the documents themselves.

## Tests

- `supabase/tests/99_r50_investor_library.sql`
- `web/src/features/investor/library.test.ts`, `web/src/lib/whats-new.test.ts` (the feed), `web/src/features/guide-me/engine.test.ts` (every step file listed)
- `web/tests/e2e/investor-library.spec.ts`
