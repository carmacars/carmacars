import Link from 'next/link';
import { notFound } from 'next/navigation';
import { CtaBand } from '@/components/Blocks';
import { Crumbs } from '@/components/Crumbs';
import { Faq } from '@/components/Faq';
import { JsonLd } from '@/components/JsonLd';
import { render } from '@/features/guides/markdown';
import { getArticle } from '@/features/seo/data';
import { breadcrumbLd, faqLd, type Trail, seoMeta } from '@/features/seo/meta';
import { fill, getSettings, getTokens, siteUrl } from '@/lib/site';
import OG from '@/features/seo/og-images.json';
import '@/styles/seo.css';

// One guide (migration 0061). The Markdown is rendered when the page is built (it is cached for an hour, then rebuilt
// in the background), with every {{token}} filled from the settings, so a fee in an article is always the live one.
export const revalidate = 3600;
export const dynamicParams = true;
type Params = { params: Promise<{ slug: string }> };

// Rendered on the first visit and kept for the hour (revalidate), not at build time: the build does not wait on the
// database for pages a visitor or the search job renders anyway (deploy run 39289461880 stopped on one).
export async function generateStaticParams() {
  return [];
}
async function load(slug: string) {
  const a = await getArticle(slug);
  if (!a) notFound();
  return a;
}
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: 'long', day: 'numeric' }).format(new Date(iso));

export async function generateMetadata({ params }: Params) {
  const a = await load((await params).slug);
  const [t, s] = await Promise.all([getTokens(), getSettings()]);
  const title = fill(a.seo_title ?? a.title, t);
  return seoMeta({ title: title.includes(s.brand_name) || title.length > 46 ? title : `${title} | ${s.brand_name}`, description: fill(a.description, t), path: a.path,
    type: 'article', published: a.published_at, modified: a.updated_at, image: OG.guides.includes(a.slug) ? `${siteUrl()}/og/guides/${a.slug}.png` : null, imageAlt: fill(a.title, t) });
}

export default async function GuidePage({ params }: Params) {
  const a = await load((await params).slug);
  const [t, s] = await Promise.all([getTokens(), getSettings()]);
  const F = (x: string) => fill(x, t);
  const html = render(F(a.body_md), { idPrefix: 'g' });
  const faq = a.faq.map((q) => ({ question: F(q.question), answer: F(q.answer) }));
  const trail: Trail = [['Home', '/'], ['Guides', '/guides'], [F(a.title)]];
  const url = siteUrl() + a.path;
  const org = { '@type': 'Organization', '@id': `${siteUrl()}/#business`, name: s.brand_name, url: `${siteUrl()}/` };
  return (
    <div className="p-article" data-page="article">
      <JsonLd graph={[breadcrumbLd(trail, a.path), ...(faq.length ? [faqLd(faq)] : []), {
        '@type': 'Article', '@id': `${url}#article`, headline: F(a.title).slice(0, 110), description: F(a.description), url, mainEntityOfPage: url, inLanguage: 'en-CA',
        datePublished: a.published_at, dateModified: a.updated_at, image: [OG.guides.includes(a.slug) ? `${siteUrl()}/og/guides/${a.slug}.png` : `${siteUrl()}/og/default.png`],
        author: a.author_name ? { '@type': 'Person', name: a.author_name, worksFor: { '@id': `${siteUrl()}/#business` } } : org, publisher: org }]} />
      <section className="page-head on-dark"><div className="wrap">
        <Crumbs trail={trail} />
        <h1 className="d1 landing__h1">{F(a.title)}</h1>
        {a.summary && <p className="lead muted">{F(a.summary)}</p>}
        <p className="art__meta">By {a.author_name ?? `the ${s.brand_name} team`}. Updated <time dateTime={a.updated_at}>{day(a.updated_at)}</time>.</p>
      </div></section>
      <div className="wrap art"><div className="art__grid">
        <article className="art__body" dangerouslySetInnerHTML={{ __html: html.html }} />
        <aside className="art__aside" aria-label="On this page and related">
          {html.tasks.length > 2 && <section><h2>On this page</h2><ul className="linklist">{html.tasks.map((x) => <li key={x.id}><a className="link" href={`#${x.id}`}>{x.title}</a></li>)}</ul></section>}
          {a.links.length > 0 && <section><h2>Related</h2><ul className="linklist">{a.links.map((l) => <li key={l.href}><Link prefetch={false} className="link" href={l.href}>{l.label}</Link></li>)}</ul></section>}
          {a.related.length > 0 && <section><h2>More guides</h2><ul className="linklist">{a.related.map((r) => <li key={r.slug}><Link prefetch={false} className="link" href={r.path}>{F(r.title)}</Link></li>)}</ul></section>}
        </aside>
      </div>
      {faq.length > 0 && <section className="car-sec art__body" aria-labelledby="h-faq"><h2 className="d2" id="h-faq">Questions</h2><Faq items={faq} /></section>}
      </div>
      <CtaBand h="Ready to rent?" p="Pick a car and send a request. No payment until we confirm." />
    </div>
  );
}
