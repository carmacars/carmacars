'use client';
import './live-map.css';
import Link from 'next/link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { money } from '@/lib/format';
import { photoUrl } from '@/lib/photo';
import { HOME_BOUNDS, MAX_BOUNDS, NEW_MS, REFRESH_MS, SPOTLIGHT_MS, inBounds, type Bounds } from './config';
import { MapEngine, type CarSpec, type PinSpec, type Spot } from './engine';
import { ICONS } from './icons';
import { CAR_HOW, FLEET_STATUS, PRECISION_WORDS, TYPE, TYPES, agoText, isNew, spotlight, spread, tally, type CarPhoto, type LeadType, type MapView, type Pin } from './model';

// Today > Live map (migration 0242): the map, the legend with live counts, the KPI tiles and a card per lead. On the
// normal page it sits in the admin frame (details masked until "Show details"); with ?tv=1 it fills the screen for a TV
// or monitor: dark, large type, no scrollbars, a spotlight that cycles the hottest leads, the cursor hidden when idle.
// It asks for fresh data every 30 seconds and changes what changed in place, so nothing flickers.

const inArea = (lng: number, lat: number) => inBounds(lng, lat, MAX_BOUNDS);
const imgOf = (p: CarPhoto | null | undefined, w = 640): string | null => {
  if (!p?.path) return null;
  const v = (p.variants ?? []).filter((x) => x?.path && x.width >= w).sort((a, b) => a.width - b.width)[0];
  return photoUrl(v?.path ?? p.path);
};

export function LiveMap({ initial, tv }: { initial: MapView | null; tv: boolean }) {
  const [view, setView] = useState<MapView | null>(initial);
  const [err, setErr] = useState('');
  const [details, setDetails] = useState(false);
  const [hidden, setHidden] = useState<Set<LeadType>>(new Set());
  const [layers, setLayers] = useState({ leads: true, fleet: true });
  const [selected, setSelected] = useState<string | null>(null);
  const [float, setFloat] = useState<{ id: string; at: Spot; pinned: boolean } | null>(null);
  const [sort, setSort] = useState<'recent' | 'score'>('recent');
  const [now, setNow] = useState(() => Date.now());
  const [spot, setSpot] = useState(0);
  const [mode, setMode] = useState<'loading' | 'map' | 'schematic'>('loading');
  const [idle, setIdle] = useState(false);
  const boxRef = useRef<HTMLDivElement>(null);
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

  // ---------------------------------------------------------------- TV: full screen, no scrollbars, the cursor hides when idle
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

  // ---------------------------------------------------------------- the map engine
  useEffect(() => {
    if (!boxRef.current) return;
    const e = new MapEngine(boxRef.current, {
      select: (id, at) => { setSelected(id); setFloat(id && at ? { id, at, pinned: true } : null); },
      hover: (id, at) => { setFloat((f) => (f?.pinned ? f : id && at ? { id, at, pinned: false } : null)); },
      moved: () => setFloat(null)
    }, { tv });
    engine.current = e;
    void e.start().then((m) => setMode(m));
    return () => { e.destroy(); engine.current = null; };
  }, [tv]);

  const pins = useMemo(() => view?.pins ?? [], [view]);
  const counts = useMemo(() => (view ? tally(view, inArea) : null), [view]);
  const placed = useMemo(() => {
    const on = pins.filter((p) => p.lat !== null && p.lng !== null && inArea(p.lng, p.lat) && !hidden.has(p.type));
    const at = new Map(spread(on.map((p) => ({ id: p.id, lng: p.lng!, lat: p.lat! }))).map((x) => [x.id, x]));
    return on.map((p) => ({ p, at: at.get(p.id)! }));
  }, [pins, hidden]);

  useEffect(() => {
    const e = engine.current;
    if (!e || mode === 'loading') return;
    const specs: PinSpec[] = layers.leads ? placed.map(({ p, at }) => ({
      id: p.id, lng: at.lng, lat: at.lat, colour: TYPE[p.type].colour, type: p.type, icon: ICONS[p.type], hot: p.band === 'hot',
      label: `${TYPE[p.type].label}: ${p.who}, score ${p.score}${p.online ? ', on the site now' : ''}`,
      pulse: p.online || isNew(p.at, NEW_MS, now), selected: p.id === selected
    })) : [];
    e.setPins(specs);
    // frame the area, widened to the pins drawn (within southern Ontario)
    const b: Bounds = [...HOME_BOUNDS];
    for (const { at } of placed) { b[0] = Math.min(b[0], at.lng - 0.05); b[1] = Math.min(b[1], at.lat - 0.05); b[2] = Math.max(b[2], at.lng + 0.05); b[3] = Math.max(b[3], at.lat + 0.05); }
    e.frame(b);
  }, [placed, layers.leads, selected, now, mode]);

  useEffect(() => {
    const e = engine.current;
    if (!e || mode === 'loading') return;
    const cars: CarSpec[] = layers.fleet ? (view?.fleet ?? []).filter((c) => inArea(c.lng, c.lat)).map((c) => ({
      id: c.vehicle_id, lng: c.lng, lat: c.lat, heading: c.heading, colour: FLEET_STATUS[c.status].colour, photo: imgOf(c.photo, 160),
      label: `${c.name}${c.code ? ` (${c.code})` : ''}: ${FLEET_STATUS[c.status].label}${c.speed ? `, ${Math.round(c.speed)} km/h` : ''}`
    })) : [];
    e.setCars(cars);
  }, [view, layers.fleet, mode]);

  // ---------------------------------------------------------------- the spotlight (TV)
  const spots = useMemo(() => (view ? spotlight(view, 8) : []), [view]);
  useEffect(() => {
    if (!tv || spots.length < 2) return;
    const t = setInterval(() => setSpot((i) => i + 1), SPOTLIGHT_MS);
    return () => clearInterval(t);
  }, [tv, spots.length]);

  const list = useMemo(() => {
    const l = pins.filter((p) => !hidden.has(p.type));
    return sort === 'score' ? [...l].sort((a, b) => b.score - a.score || (b.at > a.at ? 1 : -1)) : [...l].sort((a, b) => Number(b.online) - Number(a.online) || (b.at > a.at ? 1 : b.at < a.at ? -1 : 0));
  }, [pins, hidden, sort]);
  const byId = useMemo(() => new Map(pins.map((p) => [p.id, p])), [pins]);
  const card = float ? byId.get(float.id) ?? null : null;

  const toggleType = (t: LeadType) => setHidden((h) => { const n = new Set(h); if (n.has(t)) n.delete(t); else n.add(t); return n; });
  const fleetCount = view?.fleet.length ?? 0;
  const k = view?.kpi;

  const kpis = (
    <ul className="lm-kpis" aria-label="Today at a glance" data-testid="lm-kpis">
      <Kpi label="On the site now" v={k?.active_now ?? 0} live />
      <Kpi label="Requests today" v={k?.requests_today ?? 0} />
      <Kpi label="Bookings this week" v={k?.bookings_week ?? 0} />
      <Kpi label="On rent now" v={k?.on_rent_now ?? 0} />
      {k?.collected_month_cents !== null && k?.collected_month_cents !== undefined && <Kpi label="Collected this month" v={money(k.collected_month_cents)} />}
    </ul>
  );
  const legend = (
    <div className="lm-legend" role="group" aria-label="Kinds of pins (press to hide or show)" data-testid="lm-legend">
      {TYPES.map((t) => (
        <button key={t.type} type="button" className="lm-legend__item" aria-pressed={!hidden.has(t.type)} style={{ ['--c' as string]: t.colour }} onClick={() => toggleType(t.type)} data-type={t.type} tabIndex={tv ? -1 : 0}>
          <span className="lm-legend__dot" aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS[t.type] }} />
          <span className="lm-legend__label">{tv ? t.short : t.label}</span>
          <b className="lm-legend__n" data-testid={`lm-count-${t.type}`}>{counts?.byType[t.type] ?? 0}</b>
        </button>
      ))}
      {counts && (counts.none > 0 || counts.outside > 0) && (
        <span className="lm-legend__note" data-testid="lm-no-location">{counts.none} with no location{counts.outside ? `, ${counts.outside} outside the area` : ''}</span>
      )}
    </div>
  );
  const mapBox = (
    <div className="lm-mapwrap">
      <div ref={boxRef} className="lm-map" role="region" aria-label="Map of the Greater Toronto Area with a pin per lead" data-testid="lm-map" data-mode={mode} />
      {mode === 'schematic' && <p className="lm-map__note">Simplified map: the map tiles could not load here. <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">Places: OpenStreetMap</a></p>}
      {mode === 'loading' && <p className="lm-map__note">Loading the map</p>}
      {card && float && (
        <div className="lm-float" style={floatAt(float.at)} data-testid="lm-popup">
          <LeadCard p={card} now={now} tv={tv} compact />
        </div>
      )}
      {!tv && (
        <div className="lm-layers" role="group" aria-label="Layers">
          <label><input type="checkbox" checked={layers.leads} onChange={(e) => setLayers((l) => ({ ...l, leads: e.target.checked }))} /> Leads</label>
          <label title={fleetCount ? undefined : 'Shows each car once its tracker reports'}><input type="checkbox" checked={layers.fleet} disabled={!fleetCount} onChange={(e) => setLayers((l) => ({ ...l, fleet: e.target.checked }))} /> Fleet{fleetCount ? ` (${fleetCount})` : ': waiting for trackers'}</label>
        </div>
      )}
    </div>
  );

  if (tv) {
    const s = spots.length ? spots[spot % spots.length] : null;
    const feed = list.slice(0, 7);
    return (
      <div className={`lm lm--tv${idle ? ' lm--idle' : ''}`} data-testid="live-map-tv">
        <header className="lm-tv__head">
          <div className="lm-brand"><span className="lm-brand__live" aria-hidden="true" /> <span>CarmaCars <b>Live</b></span></div>
          {kpis}
          <Clock now={now} />
        </header>
        <main className="lm-tv__body">
          <section className="lm-tv__map" aria-label="Map">{mapBox}{legend}</section>
          <aside className="lm-tv__side">
            <section className="lm-spot" aria-label="Spotlight" aria-live="polite" data-testid="lm-spotlight">
              <h2 className="lm-h">Hottest leads <span className="lm-spot__n">{spots.length ? `${(spot % spots.length) + 1} of ${spots.length}` : ''}</span></h2>
              {s ? <Spotlight key={s.id} p={s} now={now} /> : <p className="lm-empty">No leads in the last 30 days yet.</p>}
            </section>
            <section className="lm-feed" aria-label="Latest activity">
              <h2 className="lm-h">Latest</h2>
              <ul className="lm-feed__list" data-testid="lm-cards">{feed.map((p) => <li key={p.id}><LeadCard p={p} now={now} tv compact /></li>)}</ul>
            </section>
          </aside>
        </main>
        {err && <p className="lm-err" role="status">Not refreshed: {err}. Trying again in 30 seconds.</p>}
      </div>
    );
  }

  return (
    <div className="lm lm--page" data-testid="live-map">
      <div className="lm-bar">
        {kpis}
        <div className="lm-bar__acts">
          <label className="lm-switch"><input type="checkbox" checked={details} onChange={(e) => setDetails(e.target.checked)} data-testid="lm-details" /> Show details</label>
          <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/live-map?tv=1" target="_blank" rel="noopener">Open TV mode</Link>
        </div>
      </div>
      {mapBox}
      {legend}
      {err && <p className="lm-err" role="status">Not refreshed: {err}. Trying again in 30 seconds.</p>}
      <div className="lm-listhead">
        <h2 className="lm-h">Leads <span className="lm-muted">({list.length}{view && view.pins.length >= view.cap ? `, the newest ${view.cap}` : ''}, last {view?.days ?? 30} days and current)</span></h2>
        <label className="lm-sort">Sort <select value={sort} onChange={(e) => setSort(e.target.value as 'recent' | 'score')}><option value="recent">On the site, then newest</option><option value="score">Highest score</option></select></label>
      </div>
      {list.length ? (
        <ul className="lm-cards" data-testid="lm-cards">{list.map((p) => (
          <li key={p.id} className={p.id === selected ? 'is-on' : undefined}>
            <LeadCard p={p} now={now} tv={false} onLocate={p.lat !== null && inArea(p.lng!, p.lat) ? () => { setSelected(p.id); const at = engine.current?.spotOf(p.id); setFloat(at ? { id: p.id, at, pinned: true } : null); boxRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' }); } : undefined} />
          </li>))}</ul>
      ) : <p className="lm-empty">No leads in the last 30 days yet. Visitors on the site, games, forms, requests and bookings show here as they happen.</p>}
      <p className="lm-foot small">Score: the points of the signals added up, at most 100 (60 or more is hot, 30 or more warm). Places are approximate: the visit&apos;s network (about 1 km), else the centre of the renter&apos;s home city or the visit&apos;s city; nothing is looked up. Refreshes every 30 seconds.</p>
    </div>
  );
}

function floatAt(s: Spot): React.CSSProperties {
  const x = s.x + s.w / 2, right = x > s.bw * 0.6, below = s.y < s.bh * 0.45;
  return { left: right ? undefined : Math.max(8, x + 18), right: right ? Math.max(8, s.bw - x + 18) : undefined, top: below ? Math.max(8, s.y) : undefined, bottom: below ? undefined : Math.max(8, s.bh - s.y - s.h) };
}

function Kpi({ label, v, live }: { label: string; v: React.ReactNode; live?: boolean }) {
  return <li className="lm-kpi"><span className="lm-kpi__v">{live && <span className="lm-kpi__live" aria-hidden="true" />}{v}</span><span className="lm-kpi__k">{label}</span></li>;
}

function Clock({ now }: { now: number }) {
  const d = new Date(now);
  return (
    <div className="lm-clock" aria-label="Time in Toronto">
      <b>{d.toLocaleTimeString('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' })}</b>
      <span>{d.toLocaleDateString('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric' })}</span>
    </div>
  );
}

function Score({ p, big }: { p: Pin; big?: boolean }) {
  return (
    <span className={`lm-score lm-score--${p.band}${big ? ' lm-score--big' : ''}`} style={{ ['--p' as string]: String(p.score) }} aria-label={`Score ${p.score} of 100, ${p.band}`}>
      <span aria-hidden="true">{p.score}</span>
    </span>
  );
}

function Badge({ t, extra }: { t: LeadType; extra?: LeadType[] }) {
  const also = (extra ?? []).filter((x) => x !== t);
  return (
    <span className="lm-badges">
      <span className="lm-badge" style={{ ['--c' as string]: TYPE[t].colour }}><span className="lm-badge__i" aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS[t] }} />{TYPE[t].label}</span>
      {also.map((x) => <span key={x} className="lm-badge lm-badge--also" style={{ ['--c' as string]: TYPE[x].colour }}>{TYPE[x].short}</span>)}
    </span>
  );
}

function CarLine({ p, big }: { p: Pin; big?: boolean }) {
  const c = p.car;
  if (!c) return null;
  const src = imgOf(c.photo, big ? 960 : 320);
  return (
    <div className={`lm-car-line${big ? ' lm-car-line--big' : ''}`}>
      {/* eslint-disable-next-line @next/next/no-img-element -- the photos come pre-sized (CarImage does the same) */}
      {src ? <img src={src} alt={c.photo?.alt || c.name} loading="lazy" decoding="async" width={big ? 960 : 160} height={big ? 600 : 100} /> : <span className="lm-car-line__ph" aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS.on_rent }} />}
      <span className="lm-car-line__t">
        <span className="lm-muted">{CAR_HOW[c.how] ?? 'Last viewed'}{c.photo?.sample ? ' (sample photo)' : ''}</span>
        <b>{c.name}</b>
        {c.daily_cents ? <span>{money(c.daily_cents)}/day</span> : null}
      </span>
    </div>
  );
}

function LeadCard({ p, now, tv, compact, onLocate }: { p: Pin; now: number; tv: boolean; compact?: boolean; onLocate?: () => void }) {
  const contact = [p.phone, p.email].filter(Boolean).join(' · ');
  const href = !tv && p.booking_number ? `/admin/bookings/${encodeURIComponent(p.booking_number)}` : !tv && p.renter_id ? `/admin/renters/${p.renter_id}` : null;
  return (
    <article className={`lm-card${compact ? ' lm-card--compact' : ''}`} style={{ ['--c' as string]: TYPE[p.type].colour }} data-testid="lm-card" data-type={p.type}>
      <div className="lm-card__top">
        <Badge t={p.type} extra={compact ? undefined : p.types} />
        <span className="lm-card__ago">{p.online && p.type !== 'session' ? <span className="lm-online">On the site now</span> : agoText(p.at, now)}</span>
      </div>
      <div className="lm-card__who">
        <Score p={p} />
        <span className="lm-card__name">
          <b>{href ? <Link prefetch={false} href={href}>{p.who}</Link> : p.who}</b>
          <span className="lm-muted">{[p.detail, p.city && !p.anonymous ? p.city : null].filter(Boolean).join(' · ')}</span>
          {contact && <span className="lm-card__contact">{contact}</span>}
        </span>
      </div>
      {p.signals.length > 0 && (
        <ul className="lm-chips" aria-label="Signals">{p.signals.slice(0, compact ? 3 : 5).map((s, i) => <li key={i} className={s.live ? 'is-live' : undefined}><b>+{s.points}</b> {s.label}</li>)}</ul>
      )}
      <CarLine p={p} />
      {!compact && (
        <div className="lm-card__foot">
          <span className="lm-muted">{p.precision ? PRECISION_WORDS[p.precision] : 'No location'}</span>
          {onLocate && <button type="button" className="lm-link" onClick={onLocate}>Show on the map</button>}
        </div>
      )}
    </article>
  );
}

function Spotlight({ p, now }: { p: Pin; now: number }) {
  const src = imgOf(p.car?.photo, 960);
  return (
    <article className="lm-spot__card" style={{ ['--c' as string]: TYPE[p.type].colour }} data-testid="lm-spot-card">
      <div className="lm-spot__photo">
        {/* eslint-disable-next-line @next/next/no-img-element -- the photos come pre-sized */}
        {src ? <img src={src} alt={p.car?.photo?.alt || p.car?.name || ''} decoding="async" /> : <span className="lm-spot__ph" aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS[p.type] }} />}
        {p.car && <span className="lm-spot__car"><span className="lm-muted">{CAR_HOW[p.car.how] ?? 'Last viewed'}</span> <b>{p.car.name}</b>{p.car.daily_cents ? <> · {money(p.car.daily_cents)}/day</> : null}</span>}
      </div>
      <div className="lm-spot__body">
        <div className="lm-card__top"><Badge t={p.type} extra={p.types} /><span className="lm-card__ago">{p.online && p.type !== 'session' ? <span className="lm-online">On the site now</span> : agoText(p.at, now)}</span></div>
        <div className="lm-card__who"><Score p={p} big /><span className="lm-card__name"><b className="lm-spot__name">{p.who}</b><span className="lm-muted">{[p.detail, p.city && !p.anonymous ? p.city : null].filter(Boolean).join(' · ')}</span>{p.phone && <span className="lm-card__contact">{p.phone}</span>}</span></div>
        <ul className="lm-chips" aria-label="Signals">{p.signals.slice(0, 4).map((s, i) => <li key={i} className={s.live ? 'is-live' : undefined}><b>+{s.points}</b> {s.label}</li>)}</ul>
      </div>
    </article>
  );
}
