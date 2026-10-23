import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import { faqItems, fill, getClasses, getFacts, getFleet, getSettings, getTokens, siteUrl } from '@/lib/site';
import type { ChauffeurServices } from '@/features/chauffeur/schema';
import { hubPath, placesKnown } from '@/features/places/data';
import { napAddress } from './business';
import { getArticles, getSeoPages } from './data';
import type { EntityFacts, FactLink } from './llms';

// The entity facts (docs/changes/2026-10-23-ai-search.md) for /llms.txt, /llms-full.txt, /about and the answer blocks,
// read from the database only: site settings, program settings (site_facts), the real cars (sample cars never price
// anything), the landing pages, the guides and the home page questions. Cached per request like the other reads.
const day = (s: string | null | undefined) => (s && /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : null);
const latest = (xs: Array<string | null | undefined>) => xs.map(day).filter((x): x is string => !!x).sort().pop() ?? null;
const minOf = (xs: number[]) => (xs.length ? Math.min(...xs) : null);

// the rideshare and delivery-work rental terms (0098); the companies are named only to describe the work
const WORK_TERMS = ['uber-rental-car', 'uber-eats-car-rental', 'rideshare-car-rental'];

export const getEntityFacts = cache(async (): Promise<EntityFacts> => {
  const [s, f, t, fleet, classes, pages, articles, faq, chauffeur, known] = await Promise.all([
    getSettings(), getFacts(), getTokens(), getFleet(), getClasses(), getSeoPages().catch(() => []), getArticles().catch(() => []),
    faqItems('home.faq').catch(() => []), (rpc('chauffeur_services', {}) as unknown as Promise<ChauffeurServices>).catch(() => null),
    placesKnown(['toronto']).catch(() => [] as string[])
  ]);
  const base = siteUrl();
  const real = fleet.filter((c) => !c.is_sample && c.daily_rate_cents > 0);
  const label = Object.fromEntries(classes.map((c) => [c.code, c.label]));
  const byClass = new Map<string, number[]>();
  for (const c of real) byClass.set(c.class, [...(byClass.get(c.class) ?? []), c.daily_rate_cents]);
  const nap = napAddress(s);
  const ch = chauffeur?.vehicles?.length ? chauffeur : null;
  const ix = pages.filter((p) => p.indexable);
  // the page summaries, guides and questions carry {{tokens}}; one this build does not know is dropped, never shown raw
  const F = (x: string) => { try { return fill(x, t); } catch { return x.replace(/\{\{\w+\}\}/g, '').replace(/\s+/g, ' ').trim(); } };
  const link = (p: { name: string; path: string; summary?: string }): FactLink => ({ name: F(p.name), path: p.path, ...(p.summary ? { note: F(p.summary) } : {}) });
  const toronto = known.includes('toronto');

  const services: FactLink[] = [
    { name: `Car rental in ${s.city}`, path: '/car-rental', note: 'Every way to rent, by place and by need' },
    { name: 'The fleet with live rates and calendars', path: '/cars' },
    { name: 'Delivery to your door or the airport', path: '/delivery' },
    ...(ch ? [{ name: 'Chauffeur service by the hour', path: '/chauffeur' }] : []),
    ...ix.filter((p) => p.slug === 'insurance-replacement').map((p) => ({ name: 'Insurance replacement rental', path: p.path, note: 'A car while yours is repaired; we can bill your insurer when the adjuster approves' })),
    ...(toronto ? WORK_TERMS.map((slug) => ({ name: slug === 'uber-eats-car-rental' ? 'Car rental for Uber Eats and delivery work' : slug === 'uber-rental-car' ? 'Car rental for Uber drivers' : 'Rideshare car rental',
      path: hubPath('rental', slug, 'toronto'), note: 'Weekly and monthly rates; not affiliated with or endorsed by Uber or any other platform' })) : []),
    { name: 'Car detailing', path: '/detailing' },
    { name: 'Auto body shop and collision repair', path: '/body-shop' },
    { name: 'List your car with us (owner program)', path: '/list-your-car' }
  ];
  const pagesLinks: FactLink[] = [
    { name: 'About and facts', path: '/about' }, { name: 'How it works', path: '/how-it-works' }, { name: 'Requirements to rent', path: '/requirements' },
    { name: 'Questions and answers', path: '/faq' }, { name: 'Cancellation policy', path: '/cancellation-policy' }, { name: 'Contact', path: '/contact' },
    { name: 'Rental terms', path: '/terms' }, { name: 'Privacy', path: '/privacy' }
  ];
  return {
    name: s.business?.name || s.brand_name, url: base, tagline: s.tagline,
    phone: s.phone_display, phoneE164: s.phone, whatsapp: s.whatsapp_display, email: f.email_aliases?.contact ?? s.public_email, roadside: s.roadside_phone_display,
    address: nap.line, city: s.city, region: s.region, serviceArea: s.service_area, hours: s.opening_hours_text, reply: s.reply_wording ? `We reply ${s.reply_wording}` : null,
    updated: latest([...real.map((x) => x.updated_at ?? x.published_at), ...ix.map((p) => p.lastmod), ...articles.map((a) => a.updated_at)]),
    fleet: {
      realCars: real.length,
      classes: [...byClass.entries()].map(([code, xs]) => ({ label: label[code] ?? code, count: xs.length, fromDailyCents: Math.min(...xs) })).sort((a, b) => a.fromDailyCents - b.fromDailyCents),
      fromDailyCents: minOf(real.map((x) => x.daily_rate_cents)), fromWeeklyCents: minOf(real.map((x) => x.weekly_rate_cents).filter((x) => x > 0)),
      fromMonthlyCents: minOf(real.map((x) => x.monthly_rate_cents).filter((x) => x > 0)), deliveryFromCents: minOf(real.map((x) => x.delivery_fee_cents).filter((x) => x >= 0))
    },
    drivers: { minAge: f.min_renter_age, licence: t.licence ?? '', youngBands: [t.youngA, t.youngB].filter(Boolean).join(' and ') },
    policy: {
      maxDays: f.max_rental_days, weekFrom: f.weekly_from_days, deposits: t.depMin === t.depMax ? t.depMin ?? '' : `${t.depMin} to ${t.depMax}`, hst: t.hst ?? '', noticeHours: t.notice ?? '', depositLead: t.depLead ?? '',
      cancellation: fill(`{{c1}} back within {{cGrace}} hours of booking (when pickup is {{cEarly}} hours or more away), {{c2}} at {{cEarly}} hours or more before pickup, {{c3}} between {{cLate}} and {{cEarly}} hours, none inside {{cLate}} hours`, t)
    },
    airports: f.airports.map((a) => a.name),
    chauffeurFromCents: ch ? minOf(ch.vehicles.map((v) => v.rate_3plus_cents).filter((x) => x > 0)) : null, chauffeurMinHours: ch?.min_hours ?? null,
    services,
    locations: ix.filter((p) => p.kind === 'location').map(link),
    uses: ix.filter((p) => p.kind === 'use').map(link),
    guides: articles.map((a) => ({ name: F(a.title), path: a.path, note: F(a.description) })),
    pages: pagesLinks,
    faq: faq.map((q) => ({ question: F(q.question), answer: F(q.answer) })),
    profiles: Object.values(s.social_links ?? {}).filter((v) => /^https:\/\//.test(v))
  };
});
