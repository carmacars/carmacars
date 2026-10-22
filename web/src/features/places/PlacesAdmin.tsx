'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { placesAct } from '@/server/actions/seo';

// Admin > Settings > Search, places and terms (migration 0095). Every switch is on by default; the quality gate is off.
type Res = { ok: boolean; text: string } | null;
export interface PlacesOverview {
  settings: { place_hubs_index: boolean; sale_hubs_index: boolean; detailing_hubs_index: boolean; bodyshop_hubs_index: boolean; place_quality_gate: boolean; place_delivery_reach_km: number; place_db_cap_mb: number; sale_disclaimer: string };
  regions: Array<{ code: string; name: string; country: string; enabled: boolean; places: number; loaded_at: string | null; skipped: string | null }>;
  places: Record<string, Record<string, number>>;
  terms: Array<{ slug: string; vertical: string; phrase: string; title: string; canonical_slug: string | null; served: string; intent_note: string; is_active: boolean; sort_order: number }>;
  services: Array<{ code: string; vertical: string; name: string; description: string; from_price_cents: number | null; is_active: boolean }>;
  size: { db_bytes: number; cap_bytes: number; places: number; places_bytes: number };
  imports: Array<{ id: number; regions: string[]; started_at: string; finished_at: string | null; counts: Record<string, unknown>; error: string | null }>;
  origin: { label: string };
}
const MB = (b: number) => `${Math.round(Number(b) / 1048576).toLocaleString('en-CA')} MB`;
const VERT: Record<string, string> = { rental: 'Rental', sale: 'Buying help', detailing: 'Detailing', bodyshop: 'Body shop' };

function useRun() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [res, setRes] = useState<Res>(null);
  const run = (a: Parameters<typeof placesAct>[0], p: Record<string, unknown>, ok: string) => start(async () => {
    const r = await placesAct(a, p);
    setRes(r.ok ? { ok: true, text: ok } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return { pending, res, run };
}
const Msg = ({ r }: { r: Res }) => (r ? <p className={`alert ${r.ok ? 'alert--ok' : 'alert--error'}`} role={r.ok ? 'status' : 'alert'}><span>{r.text}</span></p> : null);

export function PlaceSettings({ o }: { o: PlacesOverview }) {
  const { pending, res, run } = useRun();
  const s = o.settings;
  const [v, setV] = useState({ reach: String(s.place_delivery_reach_km), cap: String(s.place_db_cap_mb), notice: s.sale_disclaimer });
  const sw = (k: keyof PlacesOverview['settings'], label: string, help: string) => (
    <label className="check" key={k}><input type="checkbox" checked={!!s[k]} disabled={pending} onChange={(e) => run('place_settings_save', { [k]: e.target.checked }, 'Saved.')} data-testid={`ps-${k}`} />
      <span>{label}<span className="xs muted" style={{ display: 'block' }}>{help}</span></span></label>);
  return (
    <div className="stack" data-testid="place-settings">
      {sw('place_hubs_index', 'Rental place pages in search', '/car-rental/<place> and /car-rental/<term>/<place>, and their sitemaps.')}
      {sw('sale_hubs_index', 'Buying help pages in search', '/buy/<term>/<place>. They say CarmaCars does not sell, lend or lease, and take a request.')}
      {sw('detailing_hubs_index', 'Detailing place pages in search', '/detailing/<term>/<place>.')}
      {sw('bodyshop_hubs_index', 'Body shop place pages in search', '/body-shop/<term>/<place>.')}
      {sw('place_quality_gate', 'Quality gate', 'Search engines can treat many similar pages as low value. On: only places within the delivery reach are indexed, and rental pages only with a real matching car.')}
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="ps-reach">Delivery reach (km from {o.origin.label})</label><input className="input" id="ps-reach" inputMode="numeric" value={v.reach} onChange={(e) => setV({ ...v, reach: e.target.value })} /></div>
        <div className="field ad-field"><label className="label" htmlFor="ps-cap">Database size cap for the places import (MB)</label><input className="input" id="ps-cap" inputMode="numeric" value={v.cap} onChange={(e) => setV({ ...v, cap: e.target.value })} /></div>
        <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ps-notice">Notice on buying help pages</label><textarea className="input ad-textarea" id="ps-notice" rows={3} value={v.notice} onChange={(e) => setV({ ...v, notice: e.target.value })} />
          <p className="xs muted">Say &quot;we connect you&quot; only once a partner exists.</p></div>
      </div>
      <p><button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => run('place_settings_save', { place_delivery_reach_km: Number(v.reach), place_db_cap_mb: Number(v.cap), sale_disclaimer: v.notice }, 'Saved.')}>Save</button></p>
      <Msg r={res} />
    </div>
  );
}

export function PlaceRegions({ o }: { o: PlacesOverview }) {
  const { pending, res, run } = useRun();
  return (
    <div className="stack" data-testid="place-regions">
      <p className="small">Database {MB(o.size.db_bytes)} of the {MB(o.size.cap_bytes)} cap; places {o.size.places.toLocaleString('en-CA')} ({MB(o.size.places_bytes)}). A region has pages once the places workflow has loaded it (Actions, places, Run workflow).</p>
      <p className="small">{Object.entries(o.places).map(([c, k]) => `${c}: ${Object.entries(k).map(([kind, n]) => `${n.toLocaleString('en-CA')} ${kind}`).join(', ')}`).join('. ')}</p>
      <div className="ad-scroll"><table className="ad-table"><thead><tr><th scope="col">Region</th><th scope="col">Places</th><th scope="col">Loaded</th><th scope="col">Pages</th></tr></thead><tbody>
        {o.regions.map((r) => <tr key={r.code}><td>{r.name} <span className="muted xs">{r.code}</span></td><td className="num">{r.places.toLocaleString('en-CA')}</td>
          <td className="small">{r.loaded_at ? r.loaded_at.slice(0, 10) : r.skipped ?? 'Not yet'}</td>
          <td><label className="check"><input type="checkbox" checked={r.enabled} disabled={pending} onChange={(e) => run('place_settings_save', { region: r.code, enabled: e.target.checked }, `${r.name} ${e.target.checked ? 'on' : 'off'}.`)} /> <span className="vh">Pages for {r.name}</span></label></td></tr>)}
      </tbody></table></div>
      <Msg r={res} />
    </div>
  );
}

export function PlaceTerms({ o }: { o: PlacesOverview }) {
  const { pending, res, run } = useRun();
  const [add, setAdd] = useState({ vertical: 'rental', slug: '', title: '' });
  return (
    <div className="stack" data-testid="place-terms">
      {Object.keys(VERT).map((vt) => (
        <details key={vt}><summary className="link">{VERT[vt]} terms ({o.terms.filter((t) => t.vertical === vt).length})</summary>
          <div className="stack">{o.terms.filter((t) => t.vertical === vt).map((t) => <TermRow key={t.slug} t={t} run={run} pending={pending} />)}</div>
        </details>
      ))}
      <div className="row">
        <label className="vh" htmlFor="pt-v">Family</label><select className="select" id="pt-v" value={add.vertical} onChange={(e) => setAdd({ ...add, vertical: e.target.value })}>{Object.entries(VERT).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
        <label className="vh" htmlFor="pt-s">Web address</label><input className="input" id="pt-s" placeholder="web-address" value={add.slug} onChange={(e) => setAdd({ ...add, slug: e.target.value })} />
        <label className="vh" htmlFor="pt-t">Title</label><input className="input" id="pt-t" placeholder="Title" value={add.title} onChange={(e) => setAdd({ ...add, title: e.target.value })} />
        <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('place_term_save', add, 'Term added.')}>Add a term</button>
      </div>
      <h3 className="d4">Services</h3>
      {o.services.map((x) => <ServiceRow key={x.code} x={x} run={run} pending={pending} />)}
      <Msg r={res} />
    </div>
  );
}

type Run = ReturnType<typeof useRun>['run'];
function TermRow({ t, run, pending }: { t: PlacesOverview['terms'][number]; run: Run; pending: boolean }) {
  const [v, setV] = useState({ title: t.title, phrase: t.phrase, intent_note: t.intent_note, canonical_slug: t.canonical_slug ?? '', is_active: t.is_active });
  const id = `term-${t.slug}`;
  return (
    <div className="ad-fields" data-testid={id}>
      <div className="field ad-field"><label className="label" htmlFor={`${id}-t`}>{t.slug}: title</label><input className="input" id={`${id}-t`} value={v.title} onChange={(e) => setV({ ...v, title: e.target.value })} /></div>
      <div className="field ad-field"><label className="label" htmlFor={`${id}-p`}>As searched</label><input className="input" id={`${id}-p`} value={v.phrase} onChange={(e) => setV({ ...v, phrase: e.target.value })} /></div>
      <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-n`}>What is true about it (tokens allowed)</label><textarea className="input ad-textarea" id={`${id}-n`} rows={2} value={v.intent_note} onChange={(e) => setV({ ...v, intent_note: e.target.value })} /></div>
      <div className="field ad-field"><label className="label" htmlFor={`${id}-c`}>Synonym of (empty: its own pages)</label><input className="input" id={`${id}-c`} value={v.canonical_slug} onChange={(e) => setV({ ...v, canonical_slug: e.target.value })} /></div>
      <label className="check"><input type="checkbox" checked={v.is_active} onChange={(e) => setV({ ...v, is_active: e.target.checked })} /> <span>On</span></label>
      <p><button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('place_term_save', { slug: t.slug, ...v }, `${v.title} saved.`)}>Save</button></p>
    </div>
  );
}
function ServiceRow({ x, run, pending }: { x: PlacesOverview['services'][number]; run: Run; pending: boolean }) {
  const [price, setPrice] = useState(x.from_price_cents ? String(x.from_price_cents / 100) : '');
  const id = `svc-${x.code}`;
  return (
    <div className="row" data-testid={id}>
      <span className="small">{VERT[x.vertical]}: {x.name}</span>
      <label className="vh" htmlFor={id}>Starting price for {x.name}</label>
      <input className="input" id={id} inputMode="decimal" placeholder="Price on request" value={price} onChange={(e) => setPrice(e.target.value)} style={{ maxWidth: '10rem' }} />
      <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run('shop_service_save', { code: x.code, from_price_cents: price ? Math.round(Number(price) * 100) : '' }, 'Saved.')}>Save</button>
    </div>
  );
}
