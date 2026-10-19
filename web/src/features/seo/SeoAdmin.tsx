'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { seoAct } from '@/server/actions/seo';

// Admin > Settings > Search and Site (migration 0061): edit a landing page or a guide (the edited fields are locked
// and kept by every rewrite), ask for a new version, and the business listings checklist with the exact name,
// address and phone to paste into each platform.
type Res = { ok: boolean; text: string } | null;
const Msg = ({ r }: { r: Res }) => (r ? <p className={`alert ${r.ok ? 'alert--ok' : 'alert--error'}`} role={r.ok ? 'status' : 'alert'}><span>{r.text}</span></p> : null);

function useRun() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [res, setRes] = useState<Res>(null);
  const run = (action: Parameters<typeof seoAct>[0], p: Record<string, unknown>, paths: string[], ok: string) => start(async () => {
    const r = await seoAct(action, p, paths);
    setRes(r.ok ? { ok: true, text: ok } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return { pending, res, run };
}

export interface PageRow { slug: string; kind: string; name: string; path: string; is_active: boolean; locked: string[]; source: string; status: string;
  copy: { seo_title?: string; meta_description?: string; h1?: string; intro?: string; sections?: Array<{ heading: string; body: string }>; faq?: Array<{ question: string; answer: string }> };
  facts: Record<string, unknown>; match: Record<string, unknown> }

export function PageEditor({ p }: { p: PageRow }) {
  const { pending, res, run } = useRun();
  const c = p.copy;
  const [v, setV] = useState({ seo_title: c.seo_title ?? '', meta_description: c.meta_description ?? '', h1: c.h1 ?? '', intro: c.intro ?? '',
    sections: (c.sections ?? []).map((s) => `## ${s.heading}\n${s.body}`).join('\n\n'), faq: (c.faq ?? []).map((q) => `${q.question} | ${q.answer}`).join('\n'),
    facts: JSON.stringify(p.facts, null, 1), active: p.is_active });
  const id = `pe-${p.slug}`;
  const save = () => {
    const sections = v.sections.split(/^## /m).map((x) => x.trim()).filter(Boolean).map((x) => { const i = x.indexOf('\n'); return { heading: (i < 0 ? x : x.slice(0, i)).trim(), body: i < 0 ? '' : x.slice(i + 1).trim() }; });
    const faq = v.faq.split('\n').map((x) => x.split('|')).filter((x) => x[0]?.trim() && x[1]?.trim()).map(([q, a]) => ({ question: q!.trim(), answer: a!.trim() }));
    let facts: unknown;
    try { facts = JSON.parse(v.facts); } catch { run('seo_page_save', { slug: '' }, [], ''); return; }
    run('seo_page_save', { slug: p.slug, is_active: v.active, facts, copy: { seo_title: v.seo_title, meta_description: v.meta_description, h1: v.h1, intro: v.intro, sections, faq } }, [p.path, '/car-rental'], 'Saved. Edited fields are locked.');
  };
  const T = (k: 'seo_title' | 'meta_description' | 'h1' | 'intro' | 'sections' | 'faq' | 'facts', label: string, rows = 1, hint?: string) => (
    <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-${k}`}>{label}{p.locked.includes(k) ? ' (locked)' : ''}</label>
      {rows > 1 ? <textarea className="input ad-textarea" id={`${id}-${k}`} rows={rows} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
        : <input className="input" id={`${id}-${k}`} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />}
      {hint && <p className="xs muted">{hint}</p>}</div>);
  return (
    <div className="stack" data-testid={`page-editor-${p.slug}`}>
      <p className="small muted">Text may use tokens such as {'{{minAge}}'} or {'{{tollFee}}'}, filled from settings. Prices of cars are shown by the page itself: never type them.</p>
      <div className="ad-fields">
        {T('seo_title', 'Search title (60 characters at most)')}{T('meta_description', 'Search description (155 at most)', 2)}{T('h1', 'Heading')}
        {T('intro', 'Introduction', 4)}{T('sections', 'Sections', 10, 'Each section starts with "## " and its heading, then its text.')}{T('faq', 'Questions', 5, 'One a line: question | answer.')}
        {T('facts', 'Facts the writer may use (JSON)', 6, 'Places, roads, transit, rules. A change here has the page written again (locked fields are kept).')}
      </div>
      <label className="check"><input type="checkbox" checked={v.active} onChange={(e) => setV({ ...v, active: e.target.checked })} /> <span>Shown on the site</span></label>
      <p className="row">
        <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={save} data-testid={`page-save-${p.slug}`}>Save</button>
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('seo_page_save', { slug: p.slug, regenerate: true }, [p.path], 'Asked for: a new version is written within minutes. Locked fields are kept.')}>Write again</button>
        {p.locked.length > 0 && <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => run('seo_page_save', { slug: p.slug, regenerate: true, unlock: true }, [p.path], 'Unlocked and asked for a new version.')}>Unlock all and write again</button>}
      </p>
      <Msg r={res} />
    </div>
  );
}

export interface ArticleRow { slug: string; path: string; title: string; seo_title: string | null; description: string; summary: string | null; body_md: string;
  faq: Array<{ question: string; answer: string }>; author_name: string | null; is_published: boolean; brief: string | null; locked: string[]; source: string; status: string }

export function ArticleEditor({ a }: { a: ArticleRow }) {
  const { pending, res, run } = useRun();
  const [v, setV] = useState({ title: a.title, seo_title: a.seo_title ?? '', description: a.description, summary: a.summary ?? '', body_md: a.body_md,
    faq: a.faq.map((q) => `${q.question} | ${q.answer}`).join('\n'), author_name: a.author_name ?? '', brief: a.brief ?? '', published: a.is_published });
  const id = `ae-${a.slug}`;
  const T = (k: keyof Omit<typeof v, 'published'>, label: string, rows = 1, hint?: string) => (
    <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-${k}`}>{label}{a.locked.includes(k) ? ' (locked)' : ''}</label>
      {rows > 1 ? <textarea className="input ad-textarea" id={`${id}-${k}`} rows={rows} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
        : <input className="input" id={`${id}-${k}`} value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />}
      {hint && <p className="xs muted">{hint}</p>}</div>);
  const save = () => run('article_save', { slug: a.slug, title: v.title, seo_title: v.seo_title, description: v.description, summary: v.summary, body_md: v.body_md,
    faq: v.faq.split('\n').map((x) => x.split('|')).filter((x) => x[0]?.trim() && x[1]?.trim()).map(([q, x]) => ({ question: q!.trim(), answer: x!.trim() })),
    author_name: v.author_name, brief: v.brief, is_published: v.published }, [a.path, '/guides'], 'Saved. Edited fields are locked.');
  return (
    <div className="stack" data-testid={`article-editor-${a.slug}`}>
      <div className="ad-fields">
        {T('title', 'Title')}{T('seo_title', 'Search title (60 at most; empty: the title)')}{T('description', 'Search description (160 at most)', 2)}{T('summary', 'Summary under the title', 2)}
        {T('body_md', 'Article (Markdown)', 18, 'Sections start with "## ". Fees and rules as tokens, for example {{tollFee}} or {{minAge}}, so they follow the settings.')}
        {T('faq', 'Questions', 5, 'One a line: question | answer.')}{T('author_name', 'Author (empty: the CarmaCars team)')}
        {T('brief', 'Brief for the writer', 3, 'What a rewrite must cover, and the facts it may use. Numbers it may write must be here or in the current article.')}
      </div>
      <label className="check"><input type="checkbox" checked={v.published} onChange={(e) => setV({ ...v, published: e.target.checked })} /> <span>Published</span></label>
      <p className="row">
        <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={save}>Save</button>
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('article_save', { slug: a.slug, regenerate: true, brief: v.brief }, [a.path], 'Asked for: a new version is written within minutes and published when it passes the checks.')}>Write again</button>
      </p>
      <Msg r={res} />
    </div>
  );
}

export interface Listing { done?: boolean; url?: string | null; at?: string }
export const PLATFORMS: Array<[string, string, string]> = [
  ['google', 'Google Business Profile', 'https://business.google.com/create'], ['bing', 'Bing Places', 'https://www.bingplaces.com'],
  ['apple', 'Apple Business Connect', 'https://businessconnect.apple.com'], ['yelp', 'Yelp for Business', 'https://biz.yelp.ca'],
  ['yellowpages', 'Yellow Pages Canada', 'https://www.yellowpages.ca'], ['facebook', 'Facebook page', 'https://www.facebook.com/pages/create']
];

export function BusinessListings({ nap, listings }: { nap: Array<[string, string]>; listings: Record<string, Listing> }) {
  const { pending, res, run } = useRun();
  const [urls, setUrls] = useState<Record<string, string>>(Object.fromEntries(PLATFORMS.map(([k]) => [k, listings[k]?.url ?? ''])));
  // the box shows the choice at once; the database confirms it (and a refusal puts it back on the next refresh)
  const [done, setDone] = useState<Record<string, boolean>>(Object.fromEntries(PLATFORMS.map(([k]) => [k, !!listings[k]?.done])));
  const [copied, setCopied] = useState<string | null>(null);
  const copy = (k: string, v: string) => { void navigator.clipboard?.writeText(v).then(() => { setCopied(k); setTimeout(() => setCopied(null), 1500); }); };
  return (
    <div className="stack" data-testid="business-listings">
      <p className="small">Use exactly the same name, address and phone everywhere. Search engines compare them across the web, and a difference (a suite written another way, an old phone number) weakens the local listing. Paste these:</p>
      <dl className="cc-fields">{nap.map(([k, v]) => (
        <div key={k} className="cc-field"><dt><b>{k}</b></dt><dd><span style={{ whiteSpace: 'pre-line' }}>{v || 'Not set: fill it in above'}</span>{v && <> <button type="button" className="btn btn--quiet btn--sm" onClick={() => copy(k, v)}>{copied === k ? 'Copied' : 'Copy'}</button></>}</dd></div>))}</dl>
      <table className="ad-table"><thead><tr><th scope="col">Platform</th><th scope="col">Listing address</th><th scope="col">Done</th></tr></thead><tbody>
        {PLATFORMS.map(([k, label, href]) => {
          return (
            <tr key={k} data-testid={`listing-${k}`}>
              <td><a className="link" href={href} target="_blank" rel="noopener noreferrer">{label}</a></td>
              <td><label className="vh" htmlFor={`bl-${k}`}>{label} listing address</label><input className="input" id={`bl-${k}`} value={urls[k] ?? ''} placeholder="https://" onChange={(e) => setUrls({ ...urls, [k]: e.target.value })} /></td>
              <td><label className="check"><input type="checkbox" checked={!!done[k]} disabled={pending} onChange={(e) => { const v = e.target.checked; setDone({ ...done, [k]: v }); run('business_listing_tick', { platform: k, done: v, url: urls[k] }, [], v ? `${label}: done.` : `${label}: not done.`); }} /> <span>{done[k] ? 'Done' : 'To do'}</span></label></td>
            </tr>);
        })}
      </tbody></table>
      <Msg r={res} />
    </div>
  );
}
