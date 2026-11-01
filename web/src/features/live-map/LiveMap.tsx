'use client';
import './live-map.css';
import Link from 'next/link';
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { money } from '@/lib/format';
import { photoUrl } from '@/lib/photo';
import { HOME_BOUNDS, MAX_BOUNDS, NEW_MS, REFRESH_MS, SPOTLIGHT_MS, frameBounds, inBounds } from './config';
import { MapEngine, type CarSpec, type Pad, type PinSpec, type Spot } from './engine';
import { CAR_HOW, CAR_SILHOUETTE, FLEET_STATUS, carLabel, compactMoney, onTheRoad, photoPins, PRECISION_WORDS, STAGE, STAGES, TYPE, isNew, reasonOf, shortAgo, spotlight, spread, stageOf, tally, verbOf,
  type CarPhoto, type Kpi, type MapView, type Pin, type Stage } from './model';

// Today > Live map (migration 0242). The map is the hero: the site's own dark basemap with a glowing dot per lead (four
// stages, four colours), clustered where they crowd. Four numbers above it. On a TV (?tv=1): the map edge to edge on
// three quarters of the screen, a spotlight on the hottest lead and a one-line live feed on the rest, nothing to scroll,
// the pointer hidden when still. In the admin frame: the same map and numbers, then a sortable table of the leads.
// Fresh data every 30 seconds, changed in place.

const inArea = (lng: number, lat: number) => inBounds(lng, lat, MAX_BOUNDS);
const imgOf = (p: CarPhoto | null | undefined, w = 640): string | null => {
  if (!p?.path || p.sample) return null;
  const v = (p.variants ?? []).filter((x) => x?.path && x.width >= w).sort((a, b) => a.width - b.width)[0];
  return photoUrl(v?.path ?? p.path);
};
const colourOf = (p: Pin) => STAGE[stageOf(p.type)].colour;
/** What the view keeps clear: on a TV the header (its words, not its fade) and the filmstrip; on the page the layer chips. */
function padOf(box: HTMLElement | null, top: HTMLElement | null, foot: HTMLElement | null, tv: boolean): Pad {
  const edge = tv ? 28 : 16;
  if (!box) return { top: edge, right: edge, bottom: edge, left: edge };
  const b = box.getBoundingClientRect();
  const inner = (el: HTMLElement | null, end: 'bottom' | 'top') => {
    if (!el) return null;
    const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
    return end === 'bottom' ? r.bottom - parseFloat(cs.paddingBottom || '0') : r.top + parseFloat(cs.paddingTop || '0');
  };
  const t = inner(top, 'bottom'), f = inner(foot, 'top');
  // over On the road, room for one line of a city's name too (Hamilton's sits under its pin)
  const line = foot ? 1.8 * parseFloat(getComputedStyle(foot).fontSize || '16') : 0;
  return { top: Math.max(edge, t === null ? (tv ? edge : 56) : t - b.top + 8), right: edge, bottom: Math.max(edge, f === null ? edge : b.bottom - f + 8 + line), left: edge };
}

export function LiveMap({ initial, tv, at }: { initial: MapView | null; tv: boolean; /** the server's clock when the page was drawn */ at?: number }) {
  const [view, setView] = useState<MapView | null>(initial);
  const [err, setErr] = useState('');
  const [details, setDetails] = useState(false);
  const [hidden, setHidden] = useState<Set<Stage>>(new Set());
  const [layers, setLayers] = useState({ leads: true, fleet: true });
  const [float, setFloat] = useState<{ id: string; at: Spot; pinned: boolean } | null>(null);
  const [now, setNow] = useState(() => at ?? Date.now());
  const [spot, setSpot] = useState(0);
  const [mode, setMode] = useState<'loading' | 'map' | 'nogl'>('loading');
  const [idle, setIdle] = useState(false);
  const boxRef = useRef<HTMLDivElement>(null);
  const topRef = useRef<HTMLElement>(null);
  const footRef = useRef<HTMLElement>(null);
  const [size, setSize] = useState(0);
  const engine = useRef<MapEngine | null>(null);
  const first = useRef(true);

  // ---------------------------------------------------------------- data: every 30 seconds while the page is visible
  const refresh = useCallback(async () => {
    try {
      const r = await fetch(`/api/staff/live-map${details ? '?details=1' : ''}`, { cache: 'no-store', credentials: 'same-origin' });
      const j = (await r.json()) as MapView & { error?: string };
      if (!r.ok) throw new Error(j.error ?? 'Could not refresh');
      setView(j); setErr('');
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, [details]);
  useEffect(() => {
    // the first data came with the page; a later run (details turned on or off) asks at once
    if (!first.current || !initial) void refresh();
    first.current = false;
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, REFRESH_MS);
    const shown = () => { if (document.visibilityState === 'visible') void refresh(); };
    document.addEventListener('visibilitychange', shown);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', shown); };
  }, [refresh, initial]);
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 10_000); return () => clearInterval(t); }, []);

  // ---------------------------------------------------------------- TV: full screen, no scrollbars, the pointer hides when still
  useEffect(() => {
    if (!tv) return;
    document.documentElement.classList.add('lm-tv-root');
    let t: ReturnType<typeof setTimeout> | undefined;
    const move = () => { setIdle(false); clearTimeout(t); t = setTimeout(() => setIdle(true), 3000); };
    move();
    window.addEventListener('mousemove', move);
    window.addEventListener('keydown', move);
    return () => { document.documentElement.classList.remove('lm-tv-root'); window.removeEventListener('mousemove', move); window.removeEventListener('keydown', move); clearTimeout(t); };
  }, [tv]);

  // ---------------------------------------------------------------- the map
  useEffect(() => {
    if (!boxRef.current) return;
    const scale = tv ? Math.max(1, window.innerHeight / 1080) : 1;
    const e = new MapEngine(boxRef.current, {
      select: (id, at) => setFloat(id && at ? { id, at, pinned: true } : null),
      hover: (id, at) => setFloat((f) => (f?.pinned ? f : id && at ? { id, at, pinned: false } : null)),
      moved: () => setFloat((f) => (f?.pinned ? null : f))
    }, { tv, scale });
    engine.current = e;
    void e.start().then((m) => setMode(m));
    return () => { e.destroy(); engine.current = null; };
  }, [tv]);

  const pins = useMemo(() => view?.pins ?? [], [view]);
  const counts = useMemo(() => (view ? tally(view, inArea) : null), [view]);
  const placed = useMemo(() => {
    const on = pins.filter((p) => p.lat !== null && p.lng !== null && inArea(p.lng, p.lat) && !hidden.has(stageOf(p.type)));
    const at = new Map(spread(on.map((p) => ({ id: p.id, lng: p.lng!, lat: p.lat! }))).map((x) => [x.id, x]));
    return on.map((p) => ({ p, at: at.get(p.id)! }));
  }, [pins, hidden]);

  useEffect(() => {
    const e = engine.current;
    if (!e || mode !== 'map') return;
    const withPhoto = photoPins(placed.map(({ p }) => p));
    e.setPins(layers.leads ? placed.map(({ p, at }): PinSpec => ({
      id: p.id, lng: at.lng, lat: at.lat, colour: colourOf(p), stage: stageOf(p.type), hot: p.band === 'hot', live: p.online,
      fresh: isNew(p.at, NEW_MS, now), label: `${TYPE[p.type].label}: ${p.who}${p.car ? `, ${p.car.name}` : ''}`,
      photo: withPhoto.has(p.id) ? { src: imgOf(p.car?.photo, 96), initial: carLabel(p.car).initial ?? '', route: p.type === 'on_rent' || p.type === 'booking' } : undefined
    })) : []);
    // Release 26: Hamilton at the bottom, Barrie at the top, Toronto in the middle; wider only for a pin outside it, and
    // always inside the room the header and the filmstrip leave
    e.frame(HOME_BOUNDS, frameBounds(placed.map(({ at }) => at)), padOf(boxRef.current, tv ? topRef.current : null, tv ? footRef.current : null, tv));
  }, [placed, layers.leads, now, mode, tv, size]);
  // a new screen size frames again (a TV switched from 1080p to 4K, a window resized)
  useEffect(() => {
    let t: ReturnType<typeof setTimeout> | undefined;
    const on = () => { clearTimeout(t); t = setTimeout(() => setSize((n) => n + 1), 250); };
    window.addEventListener('resize', on);
    return () => { window.removeEventListener('resize', on); clearTimeout(t); };
  }, []);

  useEffect(() => { if (mode === 'map') engine.current?.setHq(view?.hq ?? null); }, [view?.hq, mode]);

  useEffect(() => {
    const e = engine.current;
    if (!e || mode !== 'map') return;
    e.setCars(layers.fleet ? (view?.fleet ?? []).filter((c) => inArea(c.lng, c.lat)).map((c): CarSpec => ({
      id: c.vehicle_id, lng: c.lng, lat: c.lat, heading: c.heading, colour: FLEET_STATUS[c.status].colour, photo: imgOf(c.photo, 160),
      label: `${c.name}${c.code ? ` (${c.code})` : ''}: ${FLEET_STATUS[c.status].label}${c.speed ? `, ${Math.round(c.speed)} km/h` : ''}`
    })) : []);
  }, [view, layers.fleet, mode]);

  // ---------------------------------------------------------------- the spotlight (TV): the hottest leads, one every 10 seconds
  const spots = useMemo(() => (view ? spotlight(view, 6) : []), [view]);
  useEffect(() => {
    if (!tv || spots.length < 2) return;
    const t = setInterval(() => setSpot((i) => i + 1), SPOTLIGHT_MS);
    return () => clearInterval(t);
  }, [tv, spots.length]);

  const byId = useMemo(() => new Map(pins.map((p) => [p.id, p])), [pins]);
  const card = float ? byId.get(float.id) ?? null : null;
  const toggleStage = (s: Stage) => setHidden((h) => { const n = new Set(h); if (n.has(s)) n.delete(s); else n.add(s); return n; });
  const fleetCount = view?.fleet.length ?? 0;

  const legend = (
    <div className="lm-legend" role="group" aria-label={tv ? 'Stages' : 'Stages (press to hide or show)'} data-testid="lm-legend">
      {STAGES.map((s) => {
        const inner = <><span className="lm-dot" aria-hidden="true" /><span>{s.label}</span><b data-testid={`lm-count-${s.stage}`}>{counts?.byStage[s.stage] ?? 0}</b></>;
        return tv ? <span key={s.stage} className="lm-legend__item" style={{ ['--c' as string]: s.colour }}>{inner}</span>
          : <button key={s.stage} type="button" className="lm-legend__item" aria-pressed={!hidden.has(s.stage)} style={{ ['--c' as string]: s.colour }} onClick={() => toggleStage(s.stage)} data-stage={s.stage}>{inner}</button>;
      })}
      {counts && (counts.none > 0 || counts.outside > 0) && <span className="lm-legend__note" data-testid="lm-no-location">{counts.none} with no location{counts.outside ? `, ${counts.outside} outside the area` : ''}</span>}
    </div>
  );
  const map = (
    <div className="lm-map" ref={boxRef} role="region" aria-label="Map of the Greater Toronto Area with a dot per lead" data-testid="lm-map" data-mode={mode}>
      {mode === 'nogl' && <p className="lm-map__note">The map needs WebGL, which this browser has turned off. The leads are listed {tv ? 'on the right' : 'below'}.</p>}
    </div>
  );
  const popup = card && float && !tv ? <div className="lm-float" style={floatAt(float.at)} data-testid="lm-popup"><PinCard p={card} now={now} /></div> : null;

  if (tv) {
    const feed = [...pins].sort((a, b) => (b.at > a.at ? 1 : b.at < a.at ? -1 : 0)).slice(0, 6);
    return (
      <div className={`lm lm--tv${idle ? ' lm--idle' : ''}`} data-testid="live-map-tv">
        <section className="lm-tv__stage" aria-label="Map">
          {map}
          <div className="lm-tv__vignette" aria-hidden="true" />
          <header className="lm-tv__top" ref={topRef}>
            <div className="lm-tv__row">
              <div className="lm-brand"><span>CarmaCars <b>Live</b></span><Clock now={now} /></div>
              <Kpis k={view?.kpi} />
            </div>
          </header>
          <footer className="lm-tv__foot" ref={footRef}><div className="lm-tv__chips">{legend}</div><Filmstrip pins={onTheRoad(pins, now)} /></footer>
        </section>
        <aside className="lm-rail">
          <section className="lm-spot" aria-label="Spotlight: the hottest lead" data-testid="lm-spotlight">
            <h2 className="lm-h">Hottest lead</h2>
            <div className="lm-spot__deck">
              {spots.length ? spots.map((p, i) => <Spotlight key={p.id} p={p} on={i === spot % spots.length} />) : <p className="lm-quiet">No leads in the last 30 days yet.</p>}
            </div>
          </section>
          <section className="lm-feed" aria-label="Live feed">
            <h2 className="lm-h">Live</h2>
            <ol className="lm-feed__list" data-testid="lm-cards">
              {feed.map((p) => (
                <li key={`${p.id}:${p.at}`} style={{ ['--c' as string]: colourOf(p) }} data-testid="lm-feed-row">
                  <span className="lm-dot" aria-hidden="true" />
                  <span className="lm-feed__t"><b>{p.who}</b> · {verbOf(p)}{p.city && !p.anonymous ? ` · ${p.city}` : ''}</span>
                  <span className="lm-feed__ago">{shortAgo(p.at, now)}</span>
                </li>))}
            </ol>
          </section>
        </aside>
        {err && <p className="lm-err" role="status">Not refreshed: {err}. Trying again in 30 seconds.</p>}
      </div>
    );
  }

  return (
    <div className="lm lm--page" data-testid="live-map">
      <div className="lm-head">
        <Kpis k={view?.kpi} />
        <div className="lm-head__acts">
          <label className="lm-check"><input type="checkbox" checked={details} onChange={(e) => setDetails(e.target.checked)} data-testid="lm-details" /> Show details</label>
          <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/live-map?tv=1" target="_blank" rel="noopener">Open TV mode</Link>
        </div>
      </div>
      <div className="lm-hero">
        {map}
        {popup}
        <div className="lm-layers" role="group" aria-label="Layers">
          <label><input type="checkbox" checked={layers.leads} onChange={(e) => setLayers((l) => ({ ...l, leads: e.target.checked }))} /> Leads</label>
          <label title={fleetCount ? undefined : 'Each car shows once its tracker reports'}><input type="checkbox" checked={layers.fleet && fleetCount > 0} disabled={!fleetCount} onChange={(e) => setLayers((l) => ({ ...l, fleet: e.target.checked }))} /> Fleet{fleetCount ? ` (${fleetCount})` : ': waiting for trackers'}</label>
        </div>
      </div>
      {legend}
      {err && <p className="lm-err" role="status">Not refreshed: {err}. Trying again in 30 seconds.</p>}
      <LeadTable pins={pins.filter((p) => !hidden.has(stageOf(p.type)))} now={now} cap={view && view.pins.length >= view.cap ? view.cap : null}
        onLocate={(id) => { boxRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' }); engine.current?.focus(id); }} />
      <p className="lm-foot">Score: the points of the signals added up, at most 100 (60 or more is hot). Places are approximate: the visit&apos;s network (about 1 km), else the centre of the renter&apos;s home city or the visit&apos;s city; nothing is looked up. Refreshes every 30 seconds. Basemap: Natural Earth; the GTA&apos;s highways drawn by CarmaCars.</p>
    </div>
  );
}

function floatAt(s: Spot): React.CSSProperties {
  const x = s.x + s.w / 2, right = x > s.bw * 0.6, below = s.y < s.bh * 0.45;
  return { left: right ? undefined : Math.max(8, x + 16), right: right ? Math.max(8, s.bw - x + 16) : undefined, top: below ? Math.max(8, s.y) : undefined, bottom: below ? undefined : Math.max(8, s.bh - s.y - s.h) };
}

function Kpis({ k }: { k: Kpi | undefined }) {
  // the one change that is cheap from the read: requests today against yesterday to the same hour
  const d = k && typeof k.requests_yesterday === 'number' ? k.requests_today - k.requests_yesterday : null;
  const delta = d === null ? null : <span className={`lm-delta${d > 0 ? ' is-up' : d < 0 ? ' is-down' : ''}`}>{d > 0 ? `+${d}` : d < 0 ? `${d}` : 'same as'} vs yesterday</span>;
  const items: Array<[string, string, boolean?, React.ReactNode?]> = [
    ['On site now', String(k?.active_now ?? 0), true], ['Requests today', String(k?.requests_today ?? 0), false, delta], ['On rent now', String(k?.on_rent_now ?? 0)],
    ['Collected this month', k?.collected_month_cents === null || k?.collected_month_cents === undefined ? '' : compactMoney(k.collected_month_cents)]
  ];
  return (
    <ul className="lm-kpis" aria-label="Today at a glance" data-testid="lm-kpis">
      {items.filter(([, v]) => v !== '').map(([label, v, live, sub]) => <li key={label}><b className="lm-kpi__v">{v}</b><span className="lm-kpi__k">{live && <span className="lm-live" aria-hidden="true" />}{label}</span>{sub}</li>)}
    </ul>
  );
}

/** On the road (TV): the cars on rent now and those picked up today, photo, car, renter (masked), due back; scrolls when it overflows. */
function Filmstrip({ pins }: { pins: Pin[] }) {
  const box = useRef<HTMLDivElement>(null), row = useRef<HTMLUListElement>(null);
  const [roll, setRoll] = useState(false);
  useEffect(() => {
    if (!box.current || !row.current || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => setRoll(!!row.current && !!box.current && row.current.scrollWidth / (roll ? 2 : 1) > box.current.clientWidth + 1));
    ro.observe(box.current); ro.observe(row.current);
    return () => ro.disconnect();
  }, [pins.length, roll]);
  const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', weekday: 'short', hour: 'numeric', minute: '2-digit' }) : '');
  const item = (p: Pin, copy: boolean) => {
    const src = imgOf(p.car?.photo, 320), car = carLabel(p.car);
    return (
      <li key={`${p.id}${copy ? ':2' : ''}`} className={car.assigned ? undefined : 'is-unassigned'} style={{ ['--c' as string]: colourOf(p) }} aria-hidden={copy || undefined} data-testid={copy ? undefined : 'lm-film-card'}>
        {/* eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized */}
        <span className="lm-film__ph">{src ? <img src={src} alt="" decoding="async" /> : car.initial ? <span>{car.initial}</span> : <CarShape />}</span>
        <span className="lm-film__t"><b>{car.name}</b><span>{p.who} · {p.type === 'on_rent' ? `back ${when(p.return_at)}` : `pickup ${when(p.pickup_at)}`}</span></span>
      </li>
    );
  };
  return (
    <div className="lm-film" ref={box} aria-label="On the road" data-testid="lm-film">
      <h2 className="lm-h">On the road <span>{pins.length}</span></h2>
      {pins.length ? <div className="lm-film__win"><ul ref={row} className={`lm-film__row${roll ? ' is-rolling' : ''}`} style={{ ['--n' as string]: String(pins.length) }}>
        {pins.map((p) => item(p, false))}{roll && pins.map((p) => item(p, true))}
      </ul></div> : <p className="lm-quiet">No car on the road today yet.</p>}
    </div>
  );
}

/** The neutral car (model.ts), for a card with no photo and nothing to take an initial from. */
function CarShape() {
  return <span className="lm-shape" dangerouslySetInnerHTML={{ __html: CAR_SILHOUETTE }} />;
}

function Clock({ now }: { now: number }) {
  return <time className="lm-clock" aria-label="Time in Toronto">{new Date(now).toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' })}</time>;
}

function Score({ p }: { p: Pin }) {
  return <span className={`lm-score lm-score--${p.band}`} style={{ ['--p' as string]: String(p.score) }} aria-label={`Score ${p.score} of 100`}><span aria-hidden="true">{p.score}</span></span>;
}

function Spotlight({ p, on }: { p: Pin; on: boolean }) {
  const src = imgOf(p.car?.photo, 960), reason = reasonOf(p.signals);
  return (
    <article className={`lm-spot__card${on ? ' is-on' : ''}${src ? ' has-photo' : ''}`} aria-hidden={!on} style={{ ['--c' as string]: colourOf(p) }} data-testid={on ? 'lm-spot-card' : undefined}>
      <div className="lm-spot__media">
        {/* eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized */}
        {src ? <img src={src} alt="" decoding="async" /> : <span className="lm-spot__car">{p.car ? carLabel(p.car).name : TYPE[p.type].label}</span>}
      </div>
      <div className="lm-spot__body">
        <Score p={p} />
        <div className="lm-spot__who">
          <b>{p.who}</b>
          <span><span className="lm-stage">{TYPE[p.type].short}</span>{p.city && !p.anonymous ? ` · ${p.city}` : ''}{src && p.car ? ` · ${p.car.name}` : ''}</span>
        </div>
      </div>
      {reason && <p className="lm-spot__why">{reason}</p>}
    </article>
  );
}

function PinCard({ p, now }: { p: Pin; now: number }) {
  const src = imgOf(p.car?.photo, 320), reason = reasonOf(p.signals);
  return (
    <article className="lm-pop" style={{ ['--c' as string]: colourOf(p) }}>
      <div className="lm-pop__top"><span className="lm-stage"><span className="lm-dot" aria-hidden="true" />{TYPE[p.type].label}</span><span className="lm-quiet">{p.online ? 'on the site now' : shortAgo(p.at, now)}</span></div>
      <div className="lm-pop__who"><Score p={p} /><span><b>{p.who}</b><span className="lm-quiet">{[p.detail, p.city && !p.anonymous ? p.city : null].filter(Boolean).join(' · ')}</span></span></div>
      {reason && <p className="lm-pop__why">{reason}</p>}
      {p.car && (
        <div className="lm-pop__car">
          {/* eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized */}
          {src && <img src={src} alt="" width={96} height={64} decoding="async" />}
          <span><span className="lm-quiet">{CAR_HOW[p.car.how] ?? 'Last viewed'}</span> {p.car.name}{p.car.daily_cents ? ` · ${money(p.car.daily_cents)}/day` : ''}</span>
        </div>
      )}
    </article>
  );
}

type SortKey = 'stage' | 'who' | 'city' | 'score' | 'reason' | 'car' | 'at';
const STAGE_ORDER: Record<Stage, number> = { booked: 0, progress: 1, site: 2, past: 3 };
function LeadTable({ pins, now, cap, onLocate }: { pins: Pin[]; now: number; cap: number | null; onLocate: (id: string) => void }) {
  const [sort, setSort] = useState<{ k: SortKey; desc: boolean }>({ k: 'at', desc: true });
  const [open, setOpen] = useState<string | null>(null);
  const rows = useMemo(() => {
    const val = (p: Pin): string | number => {
      switch (sort.k) {
        case 'stage': return STAGE_ORDER[stageOf(p.type)] * 10 + Object.keys(TYPE).indexOf(p.type);
        case 'who': return p.who.toLowerCase();
        case 'city': return (p.city ?? '~').toLowerCase();
        case 'score': return p.score;
        case 'reason': return reasonOf(p.signals).toLowerCase();
        case 'car': return (p.car?.name ?? '~').toLowerCase();
        default: return p.online ? '9' : p.at;
      }
    };
    return [...pins].sort((a, b) => { const x = val(a), y = val(b); const c = x < y ? -1 : x > y ? 1 : 0; return sort.desc ? -c : c; });
  }, [pins, sort]);
  const head = (k: SortKey, label: string, cls?: string) => (
    <th scope="col" className={cls} aria-sort={sort.k === k ? (sort.desc ? 'descending' : 'ascending') : 'none'}>
      <button type="button" onClick={() => setSort((s) => ({ k, desc: s.k === k ? !s.desc : k === 'score' || k === 'at' }))}>{label}<span aria-hidden="true">{sort.k === k ? (sort.desc ? ' ↓' : ' ↑') : ''}</span></button>
    </th>
  );
  if (!pins.length) return <p className="lm-quiet">No leads in the last 30 days yet. Visitors on the site, games, forms, requests and bookings show here as they happen.</p>;
  return (
    <div className="lm-table-wrap">
      <table className="lm-table" data-testid="lm-table">
        <caption>Leads: {pins.length}{cap ? `, the newest ${cap}` : ''}, the last 30 days and everything current. Press a row for its signals.</caption>
        <thead><tr>{head('stage', 'Stage')}{head('who', 'Name')}{head('city', 'City', 'lm-hide-s')}{head('score', 'Score', 'num')}{head('reason', 'Top reason', 'lm-hide-m')}{head('car', 'Car', 'lm-hide-m')}{head('at', 'Last seen', 'num')}</tr></thead>
        <tbody>
          {rows.map((p) => {
            const isOpen = open === p.id, href = p.booking_number ? `/admin/bookings/${encodeURIComponent(p.booking_number)}` : p.renter_id ? `/admin/renters/${p.renter_id}` : null;
            return (
              <Fragment key={p.id}>
                <tr className={isOpen ? 'is-open' : undefined} style={{ ['--c' as string]: colourOf(p) }} data-testid="lm-card" data-type={p.type}>
                  <td><span className="lm-stage"><span className="lm-dot" aria-hidden="true" />{TYPE[p.type].short}</span></td>
                  <td><button type="button" className="lm-row-btn" aria-expanded={isOpen} onClick={() => setOpen(isOpen ? null : p.id)}>{p.who}</button></td>
                  <td className="lm-hide-s">{p.city ?? ''}</td>
                  <td className="num"><span className={`lm-n lm-n--${p.band}`}>{p.score}</span></td>
                  <td className="lm-hide-m lm-quiet">{reasonOf(p.signals)}</td>
                  <td className="lm-hide-m">{p.car?.name ?? ''}</td>
                  <td className="num lm-quiet">{p.online ? <span className="lm-online">now</span> : shortAgo(p.at, now)}</td>
                </tr>
                {isOpen && (
                  <tr className="lm-more"><td colSpan={7}>
                    <div className="lm-more__in">
                      <p>{[p.detail, p.phone, p.email, p.city].filter(Boolean).join(' · ')}</p>
                      <ul className="lm-chips" aria-label="Signals">{p.signals.map((s, i) => <li key={i}><b>+{s.points}</b> {s.label}</li>)}</ul>
                      <p className="lm-quiet">{p.car ? `${CAR_HOW[p.car.how] ?? 'Last viewed'}: ${p.car.name}${p.car.daily_cents ? `, ${money(p.car.daily_cents)}/day` : ''}. ` : ''}{p.precision ? PRECISION_WORDS[p.precision] : 'No location'}.</p>
                      <p className="lm-more__acts">
                        {href && <Link prefetch={false} href={href}>{p.booking_number ? `Open ${p.booking_number}` : 'Open the renter'}</Link>}
                        {p.lat !== null && p.lng !== null && inArea(p.lng, p.lat) && <button type="button" className="lm-link" onClick={() => onLocate(p.id)}>Show on the map</button>}
                      </p>
                    </div>
                  </td></tr>
                )}
              </Fragment>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
