// Seed for the local stack (scripts/local-db.sh). Two parts:
//
//   content  Site copy an admin edits (FAQ lists, steps, cookie wording, legal pages, scene photos,
//            the owner's line). Needed in every environment: `node scripts/seed.mjs --content-only`
//            against staging or production writes the same rows.
//   guides   The six portal guides (docs/guides/content), only where a guide has none (scripts/seed-guides.mjs).
//   sample   The 20 sample cars of prototype/tools/src/data.mjs with their rates, classes, photos,
//            listings and the sample bookings that fill their calendars. Local and staging only.
//
// `--production` (the CI deploy job, at the owner's instruction until the real fleet is entered):
// content rows are only added, never overwritten (an admin's edits stay); the 20 sample cars are added
// only while the site has no listing at all, without sample bookings; the sample addresses are
// suppressed so no email goes to them. Every sample car is marked vehicles.is_sample (0035): noindex and out of the
// sitemap until an Admin clears it or unlists the car. Locally they take real bookings (vehicles.sample_bookable, 0065:
// the end-to-end tests book them); in production a request on one is an enquiry. Photos are uploaded to the public bucket by the deploy job
// (scripts/deploy/cloudflare.sh photos), not copied. Safe to run on every deploy; it never deletes.
//
// Every row goes into the real tables, as the superuser, the way an import would. Photos are copied
// from prototype/assets/photos into public/_local/vehicle-public, which the dev server serves.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import postgres from 'postgres';
import { execFileSync } from 'node:child_process';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.resolve(WEB, '..');
const PROTO = path.join(ROOT, 'prototype');
const url = process.env.DATABASE_URL || 'postgresql://postgres@127.0.0.1:54322/carmacars';
const contentOnly = process.argv.includes('--content-only');
const production = process.argv.includes('--production');
const sql = postgres(url, { onnotice: () => {}, max: 1 });

const content = JSON.parse(fs.readFileSync(path.join(WEB, 'scripts/content/site-content.json'), 'utf8'));
const photos = JSON.parse(fs.readFileSync(path.join(PROTO, 'assets/photos.json'), 'utf8'));

// ---------------------------------------------------------------- legal text
// docs/source/website_terms_policies.md is final. The numbered company name is replaced by the
// trade name (it may appear only where the law needs it), and each blank becomes a token filled
// from settings when the page renders, so no blank ever reaches a page.
function legalParts() {
  let src = fs.readFileSync(path.join(ROOT, 'docs/source/website_terms_policies.md'), 'utf8').split('\n---')[0];
  src = src
    .replace(/\d{6,} Canada Inc\.,? operating as CarmaCars/g, 'CarmaCars')
    .replace(/\d{6,} Canada Inc\.( \(CarmaCars\))?/g, 'CarmaCars')
    .replace('Last updated: [●].', 'Last updated: {{legalLastUpdated}}.')
    .replace('Contact us at [●]', 'Contact us at {{contactEmail}}')
    .replace('Our Privacy Officer is responsible for this policy: [●], [●] (email), [●] (address).', 'Our Privacy Officer is responsible for this policy: {{privacyOfficer}}.')
    .replace('Cancel in your renter portal or email [●]', 'Cancel in your renter portal or email {{bookingsEmail}}')
    .replace('including in the United States and [●].', 'including in the United States{{otherCountries}}.')
    .replace(/ – /g, ': ').replace(/[–—]/g, '-');
  const parts = src.split(/^## Part \d+\b.*$/m).slice(1).map((s) => s.trim());
  const [terms, privacy, cancellation, consents] = parts;
  const marketing = consents.split('\n').find((l) => l.startsWith('☐ Yes'))
    .replace('☐ ', '').replace('CarmaCars, [●] (address), [●] (email).', 'CarmaCars{{mailingAddress}}, {{contactEmail}}.');
  for (const [k, v] of Object.entries({ terms, privacy, cancellation, marketing })) {
    if (v.includes('[●]')) throw new Error('A blank is left in the legal text: ' + k);
  }
  return { terms, privacy, cancellation, marketing };
}

async function seedContent(tx) {
  const L = legalParts();
  const blocks = [
    ['brand.carma_line', 'global', 'text', content.carma_line, {}],
    ['cookies.banner', 'global', 'list', null, content.cookies],
    ['policy.extra', 'global', 'list', null, { accident_call_hours: 24, owner_reply: 'one business day' }],
    ['legal.meta', 'legal', 'list', null, { last_updated: content.legal_last_updated, other_countries: null }],
    ['legal.terms', 'legal', 'rich_text', L.terms, {}],
    ['legal.privacy', 'legal', 'rich_text', L.privacy, {}],
    ['legal.cancellation', 'legal', 'rich_text', L.cancellation, {}],
    ['legal.marketing_opt_in', 'legal', 'text', L.marketing, { version: content.legal_last_updated }],
    ['home.faq', 'home', 'faq', null, { items: content.home_faq }],
    ['home.how_steps', 'home', 'list', null, { items: content.how_steps }],
    ['home.requirements', 'home', 'list', null, { items: content.requirements_rows }],
    ['home.coverage_options', 'home', 'list', null, { items: content.coverage_options }],
    ['owners.faq', 'list-your-car', 'faq', null, { items: content.owner_faq }],
    ...content.faq_groups.map((g, i) => [`faq.${g.id}`, 'faq', 'faq', g.title, { id: g.id, items: g.items, order: i }]),
    ...Object.entries(photos.slots).map(([key, p]) => [`photo.${key}`, 'photos', 'list', null, {
      alt: p.alt,
      wide: { path: 'site/' + path.basename(p.wide.src), width: p.wide.width, height: p.wide.height },
      tall: { path: 'site/' + path.basename(p.tall.src), width: p.tall.width, height: p.tall.height }
    }])
  ];
  let order = 0;
  for (const [key, page, kind, body, data] of blocks) {
    if (production) {
      await tx`insert into site_content_blocks (block_key, page, kind, body, data, sort_order)
               values (${key}, ${page}, ${kind}, ${body}, ${tx.json(data)}, ${order++})
               on conflict (block_key) do nothing`;
      continue;
    }
    await tx`insert into site_content_blocks (block_key, page, kind, body, data, sort_order)
             values (${key}, ${page}, ${kind}, ${body}, ${tx.json(data)}, ${order++})
             on conflict (block_key) do update set page = excluded.page, kind = excluded.kind, body = excluded.body,
               data = excluded.data, sort_order = excluded.sort_order, is_published = true`;
  }
  return blocks.length;
}

// ---------------------------------------------------------------- landing pages and articles (0061)
// Added in every environment; a row is updated from this file only while it is still the seed's own (source seed,
// nothing locked): an Admin's edit or a rewrite by the search job is never overwritten.
async function seedSeo(tx) {
  const has = await tx`select to_regclass('public.seo_pages') is not null as ok`;
  if (!has[0].ok) return 'skipped: no 0061';
  const seo = JSON.parse(fs.readFileSync(path.join(WEB, 'scripts/content/seo-content.json'), 'utf8'));
  const hasMinReal = await tx`select exists (select 1 from information_schema.columns where table_name = 'seo_pages' and column_name = 'min_real_cars') as ok`;
  for (const p of seo.pages) {
    await tx`insert into seo_pages (slug, kind, name, sort_order, facts, match, copy, source, status)
             values (${p.slug}, ${p.kind === 'use' ? 'use' : 'location'}, ${p.name}, ${p.sort_order}, ${tx.json(p.facts)}, ${tx.json(p.match)}, ${tx.json(p.copy)}, 'seed', 'published')
             on conflict (slug) do update set name = excluded.name, sort_order = excluded.sort_order, facts = excluded.facts, match = excluded.match,
               copy = excluded.copy, copy_facts_hash = null, status = 'published'
             where seo_pages.source = 'seed' and cardinality(seo_pages.locked) = 0 and (seo_pages.copy, seo_pages.facts, seo_pages.match, seo_pages.name) is distinct from (excluded.copy, excluded.facts, excluded.match, excluded.name)`;
    // the real cars a page needs before it is indexed, when it has its own threshold (0095)
    if (hasMinReal[0].ok) await tx`update seo_pages set min_real_cars = ${p.min_real_cars ?? null} where slug = ${p.slug} and min_real_cars is distinct from ${p.min_real_cars ?? null}`;
  }
  // the seed's copy was written from these facts
  await tx`update seo_pages set copy_facts_hash = facts_hash, status = 'published' where source = 'seed' and copy_facts_hash is null`;
  for (const a of seo.articles) {
    await tx`insert into articles (slug, title, seo_title, description, summary, body_md, faq, links, topic, sort_order, brief, source, status)
             values (${a.slug}, ${a.title}, ${a.seo_title}, ${a.description}, ${a.summary}, ${a.body_md}, ${tx.json(a.faq)}, ${tx.json(a.links)}, ${a.topic}, ${a.sort_order}, ${a.brief}, 'seed', 'published')
             on conflict (slug) do update set title = excluded.title, seo_title = excluded.seo_title, description = excluded.description, summary = excluded.summary,
               body_md = excluded.body_md, faq = excluded.faq, links = excluded.links, topic = excluded.topic, sort_order = excluded.sort_order, brief = excluded.brief
             where articles.source = 'seed' and cardinality(articles.locked) = 0
               and (articles.body_md, articles.title, articles.description, articles.faq, articles.links) is distinct from (excluded.body_md, excluded.title, excluded.description, excluded.faq, excluded.links)`;
  }
  return { pages: seo.pages.length, articles: seo.articles.length };
}

// ---------------------------------------------------------------- sample cars
const SHOT = { lead: 'front_left', side: 'left', rear34: 'rear_left', front: 'front', rear: 'rear', dash: 'dashboard', seats: 'front_seats', wheel: 'wheel' };
const FUEL = { Gasoline: 'gasoline', Electric: 'electric', Hybrid: 'hybrid', Diesel: 'diesel' };
const PRICING = ['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic'];
const AREAS = ['Leslieville', 'The Annex', 'Liberty Village', 'Midtown', 'North York', 'Etobicoke', 'Scarborough', 'Yorkville', 'Danforth', 'Junction'];
const id = (label) => {
  // deterministic ids, so a reseed keeps the same links
  const h = [...label].reduce((a, c) => (Math.imul(a, 31) + c.charCodeAt(0)) >>> 0, 2166136261);
  const hex = (n) => (n >>> 0).toString(16).padStart(8, '0');
  const parts = hex(h) + hex(Math.imul(h, 2654435761)) + hex(Math.imul(h ^ 0x5bd1e995, 40503)) + hex(Math.imul(h, 97));
  return `${parts.slice(0, 8)}-${parts.slice(8, 12)}-4${parts.slice(13, 16)}-a${parts.slice(17, 20)}-${parts.slice(20, 32)}`;
};
const cents = (d) => Math.round(d * 100);

function copyPhotos() {
  const dest = path.join(WEB, 'public/_local/vehicle-public');
  fs.mkdirSync(path.join(dest, 'site'), { recursive: true });
  fs.mkdirSync(path.join(dest, 'vehicles'), { recursive: true });
  for (const f of fs.readdirSync(path.join(PROTO, 'assets/photos'))) {
    const isCar = Object.keys(photos.cars).some((slug) => f.startsWith(slug + '-'));
    fs.copyFileSync(path.join(PROTO, 'assets/photos', f), path.join(dest, isCar ? 'vehicles' : 'site', f));
  }
}

async function seedSample(tx) {
  const { CARS, PROTO_TODAY } = await import(path.join(PROTO, 'tools/src/data.mjs'));
  // The sample calendar is dated from launch day; it moves forward when the seed runs later.
  const today = new Date(new Date().toISOString().slice(0, 10) + 'T00:00:00Z');
  const anchor = new Date('2026-10-12T00:00:00Z');
  const shiftDays = Math.max(0, Math.round((today - anchor) / 864e5));
  const shift = (iso) => { const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + shiftDays); return d.toISOString().slice(0, 10); };
  void PROTO_TODAY;

  if (production) {
    for (const email of ['sample.owner@example.test', 'sample.renter@example.test']) {
      await tx`insert into email_suppressions (email, scope, reason, detail)
               select ${email}, 'all', 'manual', 'sample data address (seed)'
                where not exists (select 1 from email_suppressions where email = ${email} and lifted_at is null)`;
    }
  }
  const ownerUser = id('sample-owner-user'); const owner = id('sample-owner'); const renterUser = id('sample-renter-user'); const renter = id('sample-renter');
  await tx`insert into users (id, email, full_name) values (${ownerUser}, 'sample.owner@example.test', 'Sample Owner') on conflict do nothing`;
  await tx`insert into user_roles (user_id, role) values (${ownerUser}, 'owner') on conflict do nothing`;
  await tx`insert into owners (id, user_id, owner_type, legal_name, status, email, phone)
           values (${owner}, ${ownerUser}, 'individual', 'Sample Owner', 'active', 'sample.owner@example.test', '416-555-0100') on conflict do nothing`;
  const agreement = id('sample-agreement');
  await tx`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status)
           values (${agreement}, ${owner}, 'enrollment', 'EA-SAMPLE', '2026-08-15', 'signed') on conflict do nothing`;
  await tx`insert into users (id, email, full_name) values (${renterUser}, 'sample.renter@example.test', 'Sample Renter') on conflict do nothing`;
  await tx`insert into user_roles (user_id, role) values (${renterUser}, 'renter') on conflict do nothing`;
  await tx`insert into renters (id, user_id, legal_name, date_of_birth, mobile, email, identity_status)
           values (${renter}, ${renterUser}, 'Sample Renter', '1990-05-05', '647-555-0199', 'sample.renter@example.test', 'verified') on conflict do nothing`;

  let n = 0; let bookingNo = 0;
  for (const [i, c] of CARS.entries()) {
    const v = id('vehicle:' + c.slug);
    const lower = c.classes.map((k) => k.toLowerCase());
    const pricing = lower.find((k) => PRICING.includes(k)) || 'standard';
    const vin = ('SAMPLE' + String(i + 1).padStart(2, '0') + 'X'.repeat(17)).slice(0, 17);
    await tx`insert into vehicles (id, owner_id, fleet_number, year, make, model, trim, colour, fuel, vin, plate, class, status,
                                   management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, body_type,
                                   owner_pickup_address, is_sample, sample_bookable)
             values (${v}, ${owner}, ${c.code}, ${c.year}, ${c.make}, ${c.model}, ${c.trim}, ${c.colour}, ${FUEL[c.fuel] || 'gasoline'}, ${vin},
                     ${'SMPL' + String(i + 1).padStart(3, '0')}, ${pricing}, 'available', 'managed', 'transfer', true, '2026-09-01', '2026-09-01', ${c.body},
                     ${c.ownerPickup ? 'Sample owner address, Toronto, ON' : null}, true, ${!production})`;
    const sched = id('schedule:' + c.slug);
    await tx`insert into vehicle_schedules (id, vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status,
               management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps,
               enrollment_date, signed_at)
             values (${sched}, ${v}, ${agreement}, ${'VS-SAMPLE-' + (i + 1)}, ${i + 1}, 'individual', 'owned_outright', 'managed', 'transfer',
               45000, 2500, 10000, 3500, '2026-09-01', now())`;
    await tx`insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
             values (${v}, ${sched}, 'signed_schedule', 45000, 2500, 3500, '2026-09-01')`;
    for (const k of lower) {
      await tx`insert into vehicle_class_links (vehicle_id, class_code) values (${v}, ${k}) on conflict do nothing`;
    }
    await tx`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents,
                                     km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
             values (${v}, ${cents(c.rates.daily)}, ${cents(c.rates.weekend)}, ${cents(c.rates.weekly)}, ${cents(c.rates.monthly)},
                     ${c.kmPerDay}, ${cents(c.overage)}, ${cents(c.deposit)}, ${cents(c.delivery)}, ${cents(c.delivery)}, '2026-09-01')`;
    // per-car young driver fees (vehicle_fee_overrides) where the car differs from the default
    if (c.youngFees['18-20'] !== 35) {
      await tx`insert into vehicle_fee_overrides (vehicle_id, fee_type_code, amount_cents, effective_from)
               values (${v}, 'young_driver_18_20', ${cents(c.youngFees['18-20'])}, '2026-09-01'),
                      (${v}, 'young_driver_21_25', ${cents(c.youngFees['21-25'])}, '2026-09-01')`;
    }
    const headline = `${c.year} ${c.make} ${c.model} ${c.trim} for rent in Toronto`.slice(0, 70);
    await tx`insert into vehicle_listings (vehicle_id, slug, headline, description, features, seats, transmission, status, published_at,
                                           first_published_at, body_style, drivetrain, doors, luggage, specs, home_area, is_featured, channels)
             values (${v}, ${c.slug}, ${headline}, ${c.blurb}, ${c.features}, ${c.seats}, ${c.transmission}, 'published', now(), now(),
                     ${c.body}, ${c.drive}, ${c.doors}, ${String(c.bags)},
                     ${tx.json({ consumption: c.l100, luggage_bags: c.bags })}, ${AREAS[i % AREAS.length]}, ${i < 7}, ${['website']})`;
    for (const [j, g] of photos.cars[c.slug].gallery.entries()) {
      const file = 'vehicles/' + path.basename(g.src);
      await tx`insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, sort_order, is_cover,
                                           alt_text, width, height, variants, background_status, is_public, approved_at)
               values (${v}, ${SHOT[g.shot]}, ${SHOT[g.shot]}, ${'original/' + file}, ${file}, 'approved', ${j}, ${j === 0},
                       ${g.alt}, ${g.width}, ${g.height}, ${tx.json([])}, 'done', true, now())`;
    }
    // sample confirmed bookings: they fill the public calendar (with the 2 hour turnaround either side)
    for (const [a, b] of production ? [] : c.booked) {
      bookingNo++;
      const pickup = `${shift(a)} 10:00`; const ret = `${shift(b)} 10:00`;
      await tx`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at,
                 original_return_at, billable_days, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents,
                 rate_applied, daily_days, weekend_days, rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total,
                 overage_cents_per_km, deposit_cents, subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
               select ${'S-' + String(bookingNo).padStart(5, '0')}, 'standard', 'confirmed', ${v}, ${renter}, now(),
                 (${pickup}::text)::timestamp at time zone 'America/Toronto', (${ret}::text)::timestamp at time zone 'America/Toronto',
                 (${ret}::text)::timestamp at time zone 'America/Toronto', d, ${cents(c.rates.daily)}, ${cents(c.rates.weekend)},
                 ${cents(c.rates.weekly)}, ${cents(c.rates.monthly)}, r.rate_applied, r.daily_days, r.weekend_days, r.rental_charge_cents, 0,
                 ${c.kmPerDay}, ${c.kmPerDay} * d, ${cents(c.overage)}, ${cents(c.deposit)}, r.rental_charge_cents,
                 public.calc_hst(r.rental_charge_cents), r.rental_charge_cents + public.calc_hst(r.rental_charge_cents)
                 from (select public.calc_billable_days((${pickup}::text)::timestamp at time zone 'America/Toronto', (${ret}::text)::timestamp at time zone 'America/Toronto') d) x
                 cross join lateral public.calc_rental_charge((${pickup}::text)::timestamp at time zone 'America/Toronto', x.d,
                   ${cents(c.rates.daily)}, ${cents(c.rates.weekend)}, ${cents(c.rates.weekly)}, ${cents(c.rates.monthly)}) r`;
    }
    n++;
  }
  return { cars: n, bookings: bookingNo, shiftDays };
}

// The vehicle catalog fixture (0097), local and staging only: a small real subset of the EPA catalog with the Canadian
// trims (web/scripts/catalog/import.mjs --sql-out), so the vehicle pages work without the catalog workflow. Production
// gets the whole catalog from that workflow.
async function seedCatalog(tx) {
  const have = await tx`select count(*)::int as n from vehicle_catalog_makes`;
  if (have[0].n > 0) return 'skipped: catalog exists';
  await tx.unsafe(fs.readFileSync(path.join(ROOT, 'supabase/seed/vehicle_catalog_fixture.sql'), 'utf8'));
  return (await tx`select count(*)::int as n from vehicle_catalog_years`)[0].n + ' model years';
}

try {
  const result = await sql.begin(async (tx) => {
    await tx`select set_config('app.request_id', 'seed', true)`;
    const blocks = await seedContent(tx);
    const seo = await seedSeo(tx);
    if (contentOnly) return { blocks, seo };
    // 0093, the local stack only: the partner fleet's AI copy waits (its plain copy stands), so the end-to-end tests'
    // own cars are written first by the local writer; in production the 62 cars are written in turn as usual
    if (!production) {
      await tx`update car_copy c set next_attempt_at = now() + interval '30 days' from vehicles v
                where v.id = c.vehicle_id and v.partner_sheet_name is not null and c.status = 'pending'`;
    }
    // 0093: the partner fleet a migration imports is not "cars on the site" for the sample cars (keyed by its sheet rows)
    const already = await tx`select count(*)::int as n from vehicle_listings l join vehicles v on v.id = l.vehicle_id where v.partner_sheet_name is null`;
    const catalog = production ? 'production: the catalog workflow' : await seedCatalog(tx);
    if (already[0].n > 0) return { blocks, seo, catalog, sample: 'skipped: cars exist' };
    return { blocks, seo, catalog, ...(await seedSample(tx)) };
  });
  if (!contentOnly && !production) copyPhotos();
  console.log('seed:', JSON.stringify(result));
} finally {
  await sql.end();
}
// the user guides (0044): added where a guide has none, never overwriting an Admin's edits. A separate process with
// Node's TypeScript support, so the HTML comes from the same renderer as Admin > Settings > Guides > Publish.
execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', path.join(WEB, 'scripts/seed-guides.mjs')],
  { stdio: 'inherit', env: { ...process.env, DATABASE_URL: url } });
