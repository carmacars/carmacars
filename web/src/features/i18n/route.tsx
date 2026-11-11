import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import Link from '@/components/Link';
import { CarCard } from '@/components/CarCard';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { getSeoPage, getSeoPages } from '@/features/seo/data';
import { getEvent, getEvents } from '@/features/events/data';
import { getAirport, getAirports } from '@/features/airports/data';
import { requestHref } from '@/features/vehicles/parts';
import { pickSimilar } from '@/features/seo/steer';
import { faqLd } from '@/features/seo/meta';
import { money } from '@/lib/format';
import { getClasses, getFacts, getFleet, getSettings, siteUrl } from '@/lib/site';
import type { CarRow } from '@/lib/types';
import { translator } from './catalog';
import { getBundle, getLang, getLanguages, langAlternates, type Lang } from './data';
import '@/styles/seo.css';
import '@/styles/vehicles.css';

// The language versions of the search pages (release 36, part 2; migration 2004): /<lang>/car-rental/<landing page>,
// /<lang>/events/<event>, /<lang>/airport-car-rental/<code> and the language hub /<lang>. Built from the page's data and
// the translated templates; a string not translated yet shows in English, and a language under the coverage setting
// is noindex (Program settings seo_i18n_min_coverage_bps). Edge copy only.
export type Kind = 'landing' | 'event' | 'airport' | 'hub';
interface Built { lang: Lang; english: string; title: string; description: string; h1: string; lead: string[]; facts: Array<[string, string]>; cars: CarRow[]; want: string;
  faq: Array<{ question: string; answer: string }>; links: Array<{ href: string; label: string }>; linksTitle: string; missing: number; t: ReturnType<typeof translator>['t'] }

async function build(code: string, kind: Kind, slug: string): Promise<Built | null> {
  const lang = await getLang(code);
  if (!lang) return null;
  const [strings, s, f, fleet] = await Promise.all([getBundle(code), getSettings(), getFacts(), getFleet().catch(() => [] as CarRow[])]);
  const { t, missing } = translator(strings);
  const brand = s.brand_name;
  const real = fleet.filter((c) => !c.is_sample && c.daily_rate_cents > 0);
  const lo = real.length ? Math.min(...real.map((c) => c.daily_rate_cents)) : null;
  const deps = f.deposit_tiers_cents ?? [];
  const req = [t('req.age', { age: f.min_renter_age }), ...(deps.length ? [t('req.deposit', { min: money(Math.min(...deps)), max: money(Math.max(...deps)) })] : []), t('req.bring')];
  const faq = [{ question: t('faq.pay_q'), answer: t('faq.pay_a') }, { question: t('faq.deliver_q'), answer: t('faq.deliver_a') }];
  const base: Omit<Built, 'english' | 'title' | 'description' | 'h1' | 'lead' | 'facts' | 'cars' | 'want' | 'links' | 'linksTitle' | 'missing'> = { lang, t, faq };
  let out: Built | null = null;
  if (kind === 'landing') {
    const p = await getSeoPage(slug);
    if (!p || !p.indexable) return null;
    const place = p.name.replace(/ \(.*\)$/, '');
    const h1 = p.kind === 'location' ? t('landing.h1_location', { place }) : t('landing.h1', { name: p.name, brand });
    const lead = [t('landing.lead', { brand }), ...(p.min_daily_cents !== null ? [t('landing.prices', { count: p.car_count, price: money(p.min_daily_cents), week: money(p.min_weekly_cents ?? p.min_daily_cents * 7) })] : []), ...req];
    out = { ...base, english: `/car-rental/${slug}`, title: `${h1} | ${brand}`, description: lead[0]!, h1, lead, cars: p.cars.length ? p.cars : fleet, want: place,
      facts: [[t('facts.cars'), String(p.car_count)], ...(p.min_daily_cents !== null ? [[t('facts.from'), money(p.min_daily_cents)] as [string, string]] : []), ...(p.min_delivery_cents ? [[t('facts.delivery'), money(p.min_delivery_cents)] as [string, string]] : [])],
      links: [], linksTitle: '', missing: 0 };
  } else if (kind === 'event') {
    const e = await getEvent(slug);
    if (!e) return null;
    const when = e.starts_on && (e.ends_on ?? e.starts_on) >= new Date().toISOString().slice(0, 10) ? `${e.starts_on}${e.ends_on && e.ends_on !== e.starts_on ? ` / ${e.ends_on}` : ''}` : t('event.usually', { months: e.usual_months });
    const h1 = t('event.h1', { event: e.name });
    out = { ...base, english: `/events/${slug}`, title: `${h1} | ${brand}`, description: t('event.lead', { event: e.name, when, venue: e.venue, brand }), h1,
      lead: [t('event.lead', { event: e.name, when, venue: e.venue, brand }), ...req], cars: fleet, want: e.name,
      facts: [[t('facts.when'), when], [t('facts.venue'), e.venue], ...(lo ? [[t('facts.from'), money(lo)] as [string, string]] : [])], links: [], linksTitle: '', missing: 0 };
  } else if (kind === 'airport') {
    const a = await getAirport(slug);
    if (!a) return null;
    const h1 = t('airport.h1', { airport: `${a.name} (${a.code})` });
    out = { ...base, english: `/airport-car-rental/${slug}`, title: `${h1} | ${brand}`.slice(0, 90), description: t('airport.lead', { brand }), h1,
      lead: [t('airport.lead', { brand }), ...(a.delivery_from_cents ? [t('airport.fee', { price: money(a.delivery_from_cents) })] : []), ...req], cars: fleet, want: a.code,
      facts: [...(a.delivery_from_cents ? [[t('facts.delivery'), money(a.delivery_from_cents)] as [string, string]] : []), ...(lo ? [[t('facts.from'), money(lo)] as [string, string]] : [])], links: [], linksTitle: '', missing: 0 };
  } else {
    const [pages, events, airports] = await Promise.all([getSeoPages().catch(() => []), getEvents(), getAirports()]);
    const h1 = t('hub.h1', { language: lang.native_name });
    out = { ...base, english: '/', title: `${h1} | ${brand}`, description: t('hub.lead', { brand, language: lang.native_name }), h1, lead: [t('hub.lead', { brand, language: lang.native_name })],
      cars: fleet, want: '', facts: lo ? [[t('facts.from'), money(lo)]] : [],
      links: [...pages.filter((p) => p.indexable).map((p) => ({ href: `/${code}/car-rental/${p.slug}`, label: p.kind === 'location' ? t('landing.h1_location', { place: p.name.replace(/ \(.*\)$/, '') }) : p.name })),
        ...events.map((e) => ({ href: `/${code}/events/${e.slug}`, label: t('event.h1', { event: e.name }) })),
        ...airports.map((a) => ({ href: `/${code}/airport-car-rental/${a.code.toLowerCase()}`, label: t('airport.h1', { airport: a.code }) }))], linksTitle: t('hub.pages'), missing: 0 };
  }
  out.missing = missing.size;
  return out;
}

const pathOf = (code: string, b: Built) => (b.english === '/' ? `/${code}` : `/${code}${b.english}`);
export async function localizedMeta(code: string, kind: Kind, slug = ''): Promise<Metadata> {
  const b = await build(code, kind, slug);
  if (!b) return {};
  const base = siteUrl();
  const alternates = b.english === '/' ? { canonical: base + pathOf(code, b) } : { canonical: base + pathOf(code, b), languages: await langAlternates(b.english, base) };
  return { title: b.title, description: b.description.slice(0, 165), alternates, robots: b.lang.ready ? undefined : { index: false, follow: true },
    openGraph: { title: b.title, description: b.description.slice(0, 165), url: base + pathOf(code, b), locale: b.lang.hreflang.replace('-', '_') } };
}

export async function LocalizedPage({ code, kind, slug = '' }: { code: string; kind: Kind; slug?: string }) {
  const b = await build(code, kind, slug);
  if (!b) notFound();
  const [classes, langs] = await Promise.all([getClasses(), getLanguages()]);
  const labels = Object.fromEntries(classes.map((x) => [x.code, x.label]));
  const t = b.t;
  const cars = pickSimilar([...b.cars].sort((x, y) => x.daily_rate_cents - y.daily_rate_cents), 6, pathOf(code, b));
  return (
    <div className="p-landing" data-page="language" lang={b.lang.hreflang} dir={b.lang.dir} data-i18n-missing={b.missing}>
      <JsonLd graph={[faqLd(b.faq)]} />
      <section className="page-head on-dark">
        <div className="wrap">
          <h1 className="d1 landing__h1">{b.h1}</h1>
          {b.lead.map((p, i) => <p key={i} className="lead muted">{p}</p>)}
          <p className="row landing__cta"><Link prefetch={false} className="btn btn--primary btn--lg" href={requestHref(b.want || 'a car')} rel="nofollow">{t('common.request')}</Link>
            <Link prefetch={false} className="btn btn--ghost btn--lg" href={b.english} hrefLang="en-CA" lang="en-CA">{t('common.read_english')}</Link></p>
        </div>
      </section>
      {b.facts.length > 0 && <section className="facts on-dark" aria-label={b.h1}><div className="wrap"><dl className="facts__list">{b.facts.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl></div></section>}
      <section className="section--tight" id="cars" aria-labelledby="h-cars">
        <div className="wrap">
          <div className="section-head"><h2 className="d2" id="h-cars">{t('common.cars_ready')}</h2></div>
          <ul className="fleet-grid fleet-grid--3">{cars.map((c) => <li key={c.slug}><CarCard c={c} labels={labels} /></li>)}</ul>
          <div className="vp-request" data-testid="request-exact"><div><h3 className="d4">{t('common.request_exact')}</h3><p className="small muted">{t('common.request_exact_text')}</p></div>
            <Link prefetch={false} className="btn btn--primary" href={requestHref(b.want || 'a car')} rel="nofollow">{t('common.request')}</Link></div>
        </div>
      </section>
      <div className="wrap landing__body">
        <section className="car-sec" aria-labelledby="h-faq"><h2 className="d2" id="h-faq">{t('common.questions')}</h2><Faq items={b.faq} /></section>
        {b.links.length > 0 && <section className="car-sec landing__links" aria-labelledby="h-more"><h2 className="d2" id="h-more">{b.linksTitle}</h2>
          <nav aria-label={b.linksTitle}><ul className="linklist landing__cols">{b.links.map((l) => <li key={l.href}><Link prefetch={false} className="link" href={l.href}>{l.label}</Link></li>)}</ul></nav></section>}
        <nav aria-label="Languages" className="small"><ul className="chips">{langs.filter((l) => l.ready || l.code === code).map((l) => <li key={l.code}><Link prefetch={false} className="chip" hrefLang={l.hreflang} lang={l.hreflang} href={b.english === '/' ? `/${l.code}` : `/${l.code}${b.english}`}>{l.native_name}</Link></li>)}
          <li><Link prefetch={false} className="chip" hrefLang="en-CA" lang="en-CA" href={b.english}>English</Link></li></ul></nav>
        <p className="xs muted" data-testid="machine-note">{t('common.machine_note')}</p>
        <p className="small muted">{t('common.no_payment')}</p>
      </div>
    </div>
  );
}
