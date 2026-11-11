import Link from '@/components/Link';
import { CarCard } from '@/components/CarCard';
import { Crumbs } from '@/components/Crumbs';
import { CtaBand } from '@/components/Blocks';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import type { CarRow } from '@/lib/types';
import { breadcrumbLd, faqLd, type Trail } from './meta';
import { DepthSections } from './Depth';
import type { DepthText } from './depth';
import { ReadyCars } from './ReadyCars';
import { SiteReviews } from './SiteReviews';
import { TrackerBand } from './TrackerBand';
import '@/styles/seo.css';
import '@/styles/vehicles.css';

// The page shell of release 36's new search page families (events, airports, renting vs owning, the GPS tracker,
// and the language versions): the heading, the facts, the cars ready to book, the depth sections from the page's
// own data, real reviews, the tracker section, questions and related links. Server-rendered, no client code.
export interface ShellProps {
  path: string; trail: Trail; h1: string; lead: string[]; facts?: Array<[string, string]>; cars?: CarRow[]; labels?: Record<string, string>; want?: string;
  depth?: DepthText | null; faq?: Array<{ question: string; answer: string }>; links?: Array<{ href: string; label: string }>; linksTitle?: string;
  ld?: object[]; children?: React.ReactNode; lang?: string; dir?: 'ltr' | 'rtl'; cta?: { h: string; p: string }; carsTitle?: string; hideTracker?: boolean; testId?: string;
}
export function SeoShell(x: ShellProps) {
  const faq = x.faq ?? [];
  return (
    <div className="p-landing" data-page={x.testId ?? 'seo-family'} lang={x.lang} dir={x.dir}>
      <JsonLd graph={[breadcrumbLd(x.trail, x.path), ...(faq.length ? [faqLd(faq)] : []), ...(x.ld ?? [])]} />
      <section className="page-head on-dark">
        <div className="wrap">
          <Crumbs trail={x.trail} />
          <h1 className="d1 landing__h1">{x.h1}</h1>
          {x.lead.filter(Boolean).map((p, i) => <p key={i} className="lead muted">{p}</p>)}
        </div>
      </section>
      {x.facts && x.facts.length > 0 && (
        <section className="facts on-dark" aria-label="At a glance">
          <div className="wrap"><dl className="facts__list">{x.facts.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl></div>
        </section>
      )}
      {x.cars && (
        <section className="section--tight" id="cars" aria-labelledby="h-cars">
          <div className="wrap">
            <div className="section-head"><h2 className="d2" id="h-cars">{x.carsTitle ?? 'Cars ready to book'}</h2></div>
            {x.cars.length > 0 && x.want === undefined
              ? <ul className="fleet-grid fleet-grid--3">{x.cars.slice(0, 9).map((c) => <li key={c.slug}><CarCard c={c} labels={x.labels ?? {}} /></li>)}</ul>
              : <ReadyCars cars={x.cars} labels={x.labels ?? {}} want={x.want ?? 'the car you need'} pageKey={x.path} />}
          </div>
        </section>
      )}
      <div className="wrap landing__body">
        {x.children}
        {x.depth && <DepthSections d={x.depth} />}
        <SiteReviews />
        {!x.hideTracker && <TrackerBand />}
        {faq.length > 0 && <section className="car-sec" aria-labelledby="h-faq"><h2 className="d2" id="h-faq">Questions</h2><Faq items={faq} /></section>}
        {x.links && x.links.length > 0 && (
          <section className="car-sec landing__links" aria-labelledby="h-more">
            <h2 className="d2" id="h-more">{x.linksTitle ?? 'Related pages'}</h2>
            <nav aria-label={x.linksTitle ?? 'Related pages'}><ul className="linklist landing__cols">{x.links.map((l) => <li key={l.href}><Link prefetch={false} className="link" href={l.href}>{l.label}</Link></li>)}</ul></nav>
          </section>
        )}
      </div>
      <CtaBand h={x.cta?.h ?? 'Pick a car, send a request.'} p={x.cta?.p ?? 'No payment until we confirm the car and the price.'} />
    </div>
  );
}
