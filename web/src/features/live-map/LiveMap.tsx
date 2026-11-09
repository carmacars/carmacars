'use client';
import './live-map.css';
import Link from '@/components/Link';
import { clockTo, weekdayClockTo } from '@/lib/clock';
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { readContact, useContact, writeContact } from './contact';
import { FOCUS_EVENT, type FocusAsk } from './focus';
import { money } from '@/lib/format';
import { poller } from '@/lib/poll/poll';
import { photoUrl } from '@/lib/photo';
import { HOME_BOUNDS, MAX_BOUNDS, NEW_MS, REFRESH_MS, SPOTLIGHT_MS, frameBounds, inBounds } from './config';
import { MapEngine, type CarSpec, type EngineEvents, type Pad, type PinSpec, type Spot } from './engine';
import { CanvasMap, hasWebGL } from './canvas';

/** What LiveMap asks of a renderer: MapLibre (engine.ts) or Canvas 2D (canvas.ts). */
type Engine = Pick<MapEngine, 'start' | 'destroy' | 'setPins' | 'setCars' | 'setHq' | 'frame' | 'reframe' | 'focus' | 'screenOf'>;
import { roleLabel } from './roles';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { CAR_HOW, CAR_SILHOUETTE, FLEET_STATUS, adminHref, staffHref, carLabel, timeLine, withoutContact, compactMoney, onTheRoad, photoPins, PRECISION_WORDS, STAGE, STAGES, TYPE, isNew, reasonOf, shortAgo, spotlight, isLead, spread, stageOf, tally, verbOf,
  type CarPhoto, type Kpi, type MapView, type Pin, type Stage, failedNote, celebrationText, type Celebration } from './model';

// Today > Live map (migration 0242). The map is the hero: the site's own dark basemap with a glowing dot per lead (four
// stages, four colours), clustered where they crowd. Four numbers above it. On a TV (?tv=1): the map edge to edge on
// three quarters of the screen, a spotlight on the hottest lead and a one-line live feed on the rest, nothing to scroll,
// the pointer hidden when still. In the admin frame: the same map and numbers, then a sortable table of the leads.
// Fresh data every 30 seconds, changed in place.

const inArea = (lng: number, lat: number) => inBounds(lng, lat, MAX_BOUNDS);
/** Release 26: how long a card stays open on a TV ("Show contact" is remembered in contact.ts). */
const CARD_MS = 20_000;
/** Scrolling to the map: smooth, or at once for someone who asked for less motion. */
const scrollMotion = (): ScrollBehavior => (typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth');

const HOVER_MS = 150;
const GRACE_MS = 300;
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

export function LiveMap({ initial, tv, at, embedded = false, portal = 'admin' }: { initial: MapView | null; tv: boolean; /** the server's clock when the page was drawn */ at?: number;
  /** r27 consolidation: the staff Visitors page (customer service and Sales): staff links, no TV mode */ portal?: 'admin' | 'staff';
  /** Release 26: on the Visitors page, which has its own list (Live now and History) under the map: no table of leads here */
  embedded?: boolean }) {
  const [view, setView] = useState<MapView | null>(initial);
  const [err, setErr] = useState('');
  // Release 26: "Show contact" (phones and emails), hidden by default and remembered on this device
  const contact = useContact();
  const showContact = (on: boolean) => {
    // off: the phones and emails leave the page at once, before the next read
    if (!on) setView((v) => (v ? withoutContact(v) : v));
    writeContact(on);
  };
  const [hidden, setHidden] = useState<Set<Stage>>(new Set());
  const [layers, setLayers] = useState({ leads: true, fleet: true });
  // the open detail card: at a pin's spot, or docked (from a list) when `at` is null
  const [float, setFloat] = useState<{ id: string; at: Spot | null; pinned: boolean } | null>(null);
  const [now, setNow] = useState(() => at ?? Date.now());
  const [spot, setSpot] = useState(0);
  const [mode, setMode] = useState<'loading' | 'map' | 'nogl'>('loading');
  const [renderer, setRenderer] = useState<'webgl' | 'canvas' | null>(null);
  const [idle, setIdle] = useState(false);
  const boxRef = useRef<HTMLDivElement>(null);
  const topRef = useRef<HTMLElement>(null);
  const footRef = useRef<HTMLElement>(null);
  const [size, setSize] = useState(0);
  const engine = useRef<Engine | null>(null);
  const hoverT = useRef<{ show?: ReturnType<typeof setTimeout>; hide?: ReturnType<typeof setTimeout> }>({});
  useEffect(() => () => { clearTimeout(hoverT.current.show); clearTimeout(hoverT.current.hide); }, []);
  const first = useRef(true);

  // ---------------------------------------------------------------- data: every 30 seconds while the page is visible
  const refresh = useCallback(async () => {
    try {
      const r = await fetch(`/api/staff/live-map${contact ? '?contact=1' : ''}`, { cache: 'no-store', credentials: 'same-origin' });
      const j = (await r.json()) as MapView & { error?: string };
      if (!r.ok) throw new Error(j.error ?? 'Could not refresh');
      // an answer that left after the switch went off is not used with its contact details
      setView(readContact() ? j : withoutContact(j)); setErr('');
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, [contact]);
  useEffect(() => {
    // the first data came with the page; a later run (Show contact turned on or off) asks at once
    if (!first.current || !initial) void refresh();
    first.current = false;
    // 0320: a wall screen nobody touches asks once a minute (lib/poll); someone using it, every REFRESH_MS
    const due = poller(REFRESH_MS);
    const t = setInterval(() => { if (due()) void refresh(); }, REFRESH_MS);
    const shown = () => { if (document.visibilityState === 'visible') void refresh(); };
    document.addEventListener('visibilitychange', shown);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', shown); };
  }, [refresh, initial]);
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 10_000); return () => clearInterval(t); }, []);

  // ---------------------------------------------------------------- the detail card: Escape closes it; on a TV it closes by itself after 20 seconds
  const openId = float?.pinned ? float.id : null;
  useEffect(() => {
    if (!openId) return;
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') { setFloat(null); if (tv) engine.current?.reframe(); } };
    window.addEventListener('keydown', key);
    const t = tv ? setTimeout(() => { setFloat(null); engine.current?.reframe(); }, CARD_MS) : undefined;
    return () => { window.removeEventListener('keydown', key); clearTimeout(t); };
  }, [openId, tv]);

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
    const box = boxRef.current, events: EngineEvents = {
      select: (id, at) => setFloat(id && at ? { id, at, pinned: true } : null),
      // Release 26: hovering (or focusing) a lead previews its card after 150 ms; leaving hides it after a short grace, so
      // the pointer can move onto the card; a click pins it
      hover: (id, at) => {
        clearTimeout(hoverT.current.show); clearTimeout(hoverT.current.hide);
        if (id && at) hoverT.current.show = setTimeout(() => setFloat((f) => (f?.pinned ? f : { id, at, pinned: false })), HOVER_MS);
        else hoverT.current.hide = setTimeout(() => setFloat((f) => (f?.pinned ? f : null)), GRACE_MS);
      },
      moved: () => setFloat((f) => (f?.pinned ? null : f))
    };
    // Release 26: WebGL (MapLibre) when the browser has it; otherwise, or when MapLibre cannot start, the same map in
    // Canvas 2D (canvas.ts), so the map always draws
    let dead = false, e: Engine = new MapEngine(box, events, { tv, scale });
    engine.current = e;
    void (async () => {
      let m = hasWebGL() ? await e.start() : 'nogl';
      if (dead) return;
      if (m === 'map') { setRenderer('webgl'); setMode('map'); return; }
      e.destroy();
      e = new CanvasMap(box, events, { tv, scale });
      engine.current = e;
      m = await e.start();
      if (dead) return;
      setRenderer(m === 'map' ? 'canvas' : null);
      setMode(m);
    })();
    return () => { dead = true; e.destroy(); engine.current = null; };
  }, [tv]);

  // 1068: a booking just confirmed: confetti and a pulse at the renter's place (the map's middle when not placed) and a
  // toast with the car and the Sales credit; each plays once on this screen; less motion: the toast only
  const [party, setParty] = useState<{ c: Celebration; x: number; y: number } | null>(null);
  const seen = useRef<Set<string> | null>(null);
  useEffect(() => {
    const list = view?.celebrations ?? [];
    if (!list.length || party) return;
    if (!seen.current) { try { seen.current = new Set(JSON.parse(localStorage.getItem('cc-lm-party') ?? '[]') as string[]); } catch { seen.current = new Set(); } }
    const c = list.find((x) => !seen.current!.has(x.booking_number));
    if (!c) return;
    seen.current.add(c.booking_number);
    try { localStorage.setItem('cc-lm-party', JSON.stringify([...seen.current].slice(-50))); } catch { /* private mode */ }
    const box = boxRef.current, p = (view?.pins ?? []).find((x) => x.booking_number === c.booking_number && x.lat !== null && x.lng !== null);
    const at = p ? engine.current?.screenOf(p.lng!, p.lat!) ?? null : null;
    const w = box?.clientWidth ?? 0, h = box?.clientHeight ?? 0;
    const inside = at && at.x >= 0 && at.y >= 0 && at.x <= w && at.y <= h;
    setParty({ c, x: inside ? at.x : w / 2, y: inside ? at.y : h / 2 });
  }, [view?.celebrations, view?.pins, party]);
  useEffect(() => { if (!party) return; const t = setTimeout(() => setParty(null), 7000); return () => clearTimeout(t); }, [party]);

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
      id: p.id, lng: at.lng, lat: at.lat, colour: colourOf(p), stage: stageOf(p.type), hot: p.band === 'hot' && isLead(p), live: p.online,
      fresh: isNew(p.at, NEW_MS, now), label: `${TYPE[p.type].label}: ${p.who}${p.car ? `, ${p.car.name}` : ''}`, who: p.who, known: !p.anonymous, lead: isLead(p), score: p.score,
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
  // Release 26: a row of the Visitors page's list asks the map for its lead (by the visit or the renter); the map
  // brings it to the middle and opens its card, and says so (detail.found) so the row knows
  useEffect(() => {
    const on = (e: Event) => {
      const d = (e as CustomEvent<FocusAsk>).detail;
      const p = pins.find((x) => (d.session_id && x.session_id === d.session_id) || (d.renter_id && x.renter_id === d.renter_id) || (d.booking_number && x.booking_number === d.booking_number));
      if (!p || p.lat === null || p.lng === null || !inArea(p.lng, p.lat) || hidden.has(stageOf(p.type))) return;
      d.found = true;
      boxRef.current?.scrollIntoView({ behavior: scrollMotion(), block: 'center' });
      engine.current?.focus(p.id);
    };
    window.addEventListener(FOCUS_EVENT, on);
    return () => window.removeEventListener(FOCUS_EVENT, on);
  }, [pins, hidden]);
  const card = float ? byId.get(float.id) ?? null : null;
  const toggleStage = (s: Stage) => setHidden((h) => { const n = new Set(h); if (n.has(s)) n.delete(s); else n.add(s); return n; });
  const fleetCount = view?.fleet.length ?? 0;
  // 1080: a layer that could not be read says so, instead of zeros
  const partNote = failedNote(view?.failed);

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
    <div className="lm-map" ref={boxRef} role="region" aria-label="Map of the Greater Toronto Area with a dot per lead" data-testid="lm-map" data-mode={mode} data-renderer={renderer ?? undefined}>
      {party && <Party c={party.c} x={party.x} y={party.y} />}
      {renderer === 'canvas' && <p className="lm-map__slow" data-testid="lm-slow">Faster with hardware acceleration on (Chrome Settings &gt; System)</p>}
      {mode === 'nogl' && <p className="lm-map__note">The map needs WebGL, which this browser has turned off. The leads are listed {tv ? 'on the right' : 'below'}.</p>}
    </div>
  );
  // closing a card: a TV goes back to its frame; on the page the map stays where the user put it
  const close = useCallback(() => { setFloat(null); if (tv) engine.current?.reframe(); }, [tv]);
  const popup = card && float ? (
    <div className={`lm-float${float.at ? '' : ' lm-float--dock'}`} style={float.at ? floatAt(float.at) : undefined} data-testid="lm-popup" data-pinned={float.pinned ? '1' : '0'}
      onMouseEnter={() => clearTimeout(hoverT.current.hide)}
      onMouseLeave={() => { if (!float.pinned) hoverT.current.hide = setTimeout(() => setFloat((f) => (f?.pinned ? f : null)), GRACE_MS); }}>
      <PinCard p={card} now={now} contact={!!view?.contact} onClose={float.pinned ? close : undefined} tv={tv} portal={portal} />
    </div>) : null;
  const contactSwitch = (
    <button type="button" role="switch" aria-checked={contact} className={`lm-switch${contact ? ' is-on' : ''}`} onClick={() => showContact(!contact)} data-testid="lm-contact">
      <span className="lm-switch__track" aria-hidden="true"><span className="lm-switch__knob" /></span>Show contact
    </button>);
  const openCard = (id: string) => setFloat({ id, at: null, pinned: true });

  if (tv) {
    const feed = [...pins].sort((a, b) => (b.at > a.at ? 1 : b.at < a.at ? -1 : 0)).slice(0, 6);
    return (
      <div className={`lm lm--tv${idle ? ' lm--idle' : ''}`} data-testid="live-map-tv">
        <section className="lm-tv__stage" aria-label="Map">
          {map}
          <div className="lm-tv__vignette" aria-hidden="true" />
          {popup}
          <header className="lm-tv__top" ref={topRef}>
            <div className="lm-tv__row">
              <div className="lm-brand"><span>CarmaCars <b>Live</b></span><Clock now={now} /></div>
              {!view?.failed?.includes('kpi') && <Kpis k={view?.kpi} />}
        <TeamNow v={view} />
            </div>
          </header>
          <footer className="lm-tv__foot" ref={footRef}><div className="lm-tv__chips">{legend}</div><Filmstrip pins={onTheRoad(pins, now)} onOpen={openCard} /></footer>
        </section>
        <aside className="lm-rail">
          <div className="lm-rail__acts">{contactSwitch}</div>
          <section className="lm-spot" aria-label="Spotlight: the hottest lead" data-testid="lm-spotlight">
            <h2 className="lm-h">Hottest lead</h2>
            <div className="lm-spot__deck">
              {spots.length ? spots.map((p, i) => <Spotlight key={p.id} p={p} on={i === spot % spots.length} />) : <p className="lm-spot__empty" data-testid="lm-spot-empty">No hot leads right now</p>}
            </div>
          </section>
          <section className="lm-feed" aria-label="Live feed">
            <h2 className="lm-h">Live</h2>
            <ol className="lm-feed__list" data-testid="lm-cards">
              {feed.map((p) => (
                <li key={`${p.id}:${p.at}`} style={{ ['--c' as string]: colourOf(p) }} data-testid="lm-feed-row">
                  <button type="button" className="lm-feed__btn" onClick={() => openCard(p.id)}>
                    <span className="lm-dot" aria-hidden="true" />
                    <span className="lm-feed__t"><b>{p.who}</b> · {verbOf(p)}{p.city && !p.anonymous ? ` · ${p.city}` : ''}</span>
                    <span className="lm-feed__ago">{shortAgo(p.at, now)}</span>
                  </button>
                </li>))}
            </ol>
          </section>
        </aside>
        {err ? <p className="lm-err" role="status">Not refreshed: {err}. Trying again in 30 seconds.</p>
          : partNote ? <p className="lm-err lm-err--part" role="status" data-testid="lm-failed">{partNote}</p> : null}
      </div>
    );
  }

  return (
    <div className="lm lm--page" data-testid="live-map">
      <div className="lm-head">
        {view?.failed?.includes('kpi') ? <span /> : <Kpis k={view?.kpi} />}
        <TeamNow v={view} />
        <div className="lm-head__acts">
          {contactSwitch}
          {portal === 'admin' && <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/live-map?tv=1" target="_blank" rel="noopener">Open TV mode</Link>}
        </div>
      </div>
      <div className="lm-hero">
        {map}
        {popup}
        <div className="lm-layers" role="group" aria-label="Layers">
          <label><input type="checkbox" checked={layers.leads} onChange={(e) => setLayers((l) => ({ ...l, leads: e.target.checked }))} /> Leads</label>
          <label title={fleetCount ? undefined : 'Each car shows once its tracker reports'}><input type="checkbox" checked={layers.fleet && fleetCount > 0} disabled={!fleetCount} onChange={(e) => setLayers((l) => ({ ...l, fleet: e.target.checked }))} /> Fleet{fleetCount ? ` (${fleetCount}${view?.fleet_demo ? ', demo' : ''})` : ': waiting for trackers'}</label>
        </div>
      </div>
      {legend}
      {err && <p className="lm-err" role="status">Not refreshed: {err}. Trying again in 30 seconds.</p>}
      {!err && partNote && <p className="lm-err lm-err--part" role="status" data-testid="lm-failed">{partNote}</p>}
      {!embedded && <LeadTable pins={pins.filter((p) => !hidden.has(stageOf(p.type)))} now={now} cap={view && view.pins.length >= view.cap ? view.cap : null}
        onLocate={(id) => { boxRef.current?.scrollIntoView({ behavior: scrollMotion(), block: 'center' }); engine.current?.focus(id); }} />}
      <p className="lm-foot">Score: the points of the signals added up, at most 100 (60 or more is hot). Places are approximate: the visit&apos;s network (about 1 km), else the centre of the renter&apos;s home city or the visit&apos;s city; nothing is looked up. Refreshes every 30 seconds. Basemap: Natural Earth; boundaries: Statistics Canada via geoBoundaries (ODbL); the GTA&apos;s highways, arterial roads and ridges drawn by CarmaCars.</p>
    </div>
  );
}

function floatAt(s: Spot): React.CSSProperties {
  // a card at a pin: beside it, on whichever side has room
  // a narrow map (a phone): along the map's foot, the full width
  if (s.bw < 560) return { left: 8, right: 8, bottom: 8, width: 'auto' };
  const x = s.x + s.w / 2, right = x > s.bw * 0.6, below = s.y < s.bh * 0.45;
  return { left: right ? undefined : Math.max(8, x + 16), right: right ? Math.max(8, s.bw - x + 16) : undefined, top: below ? Math.max(8, s.y) : undefined, bottom: below ? undefined : Math.max(8, s.bh - s.y - s.h) };
}

/** 1064: who is working now (clocked in or on a field shift) and the week's Sales leaderboard, on the same live read. */
function TeamNow({ v }: { v: MapView | null | undefined }) {
  if (!v || (!v.working.length && !v.leaderboard.length)) return null;
  const since = (iso: string) => clockTo(iso); // the same words on the server and in the browser (lib/clock)
  return (
    <div className="lm-team" data-testid="lm-team">
      {v.working.length > 0 && <section aria-label="Working now"><p className="lm-kpi__k">Working now ({v.working.length})</p>
        <ul>{v.working.map((w) => <li key={`${w.name}-${w.since}`}>{w.name} <span className="lm-quiet">{w.role}, since {since(w.since)}</span></li>)}</ul></section>}
      {v.leaderboard.length > 0 && <section aria-label="Sales this week"><p className="lm-kpi__k">Sales this week</p>
        <ol>{v.leaderboard.map((l) => <li key={l.name}>{l.name} <span className="lm-quiet">{l.bookings} booking{l.bookings === 1 ? '' : 's'}</span></li>)}</ol></section>}
    </div>
  );
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
function Filmstrip({ pins, onOpen }: { pins: Pin[]; onOpen: (id: string) => void }) {
  const box = useRef<HTMLDivElement>(null), row = useRef<HTMLUListElement>(null);
  const [roll, setRoll] = useState(false);
  useEffect(() => {
    if (!box.current || !row.current || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => setRoll(!!row.current && !!box.current && row.current.scrollWidth / (roll ? 2 : 1) > box.current.clientWidth + 1));
    ro.observe(box.current); ro.observe(row.current);
    return () => ro.disconnect();
  }, [pins.length, roll]);
  const when = (iso: string | null) => (iso ? weekdayClockTo(iso) : '');
  const item = (p: Pin, copy: boolean) => {
    const src = imgOf(p.car?.photo, 320), car = carLabel(p.car);
    return (
      <li key={`${p.id}${copy ? ':2' : ''}`} className={car.assigned ? undefined : 'is-unassigned'} style={{ ['--c' as string]: colourOf(p) }} aria-hidden={copy || undefined} data-testid={copy ? undefined : 'lm-film-card'}
        role={copy ? undefined : 'button'} tabIndex={copy ? -1 : 0} aria-label={copy ? undefined : `${car.name}, ${p.who}: open the card`}
        onClick={() => onOpen(p.id)} onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpen(p.id); } }}>
        {/* eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized */}
        <span className="lm-film__ph">{src ? <img src={src} alt="" decoding="async" /> : car.initial ? <span>{car.initial}</span> : <CarShape />}</span>
        <span className="lm-film__t"><b>{car.name}</b><span>{p.who} · {p.type === 'on_rent' ? `back ${when(p.return_at)}` : `pickup ${when(p.pickup_at)}`}</span></span>
      </li>
    );
  };
  return (
    <div className="lm-film" ref={box} role="region" aria-label="On the road" data-testid="lm-film">
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
  return <time className="lm-clock" aria-label="Time in Toronto">{clockTo(now)}</time>;
}

function Score({ p }: { p: Pin }) {
  // hot and warm are for leads; a renter's score shows plain (Release 26)
  return <span className={`lm-score lm-score--${isLead(p) ? p.band : 'cold'}`} style={{ ['--p' as string]: String(p.score) }} role="img" aria-label={`Score ${p.score} of 100`}><span aria-hidden="true">{p.score}</span></span>;
}

function Spotlight({ p, on }: { p: Pin; on: boolean }) {
  // why they are the hottest lead: their three strongest signals
  const src = imgOf(p.car?.photo, 960), why = [...p.signals].sort((a, b) => b.points - a.points).slice(0, 3);
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
      {why.length > 0 && <ul className="lm-chips lm-spot__why" aria-label="Why">{why.map((x, i) => <li key={i}><b>+{x.points}</b> {x.label}</li>)}</ul>}
    </article>
  );
}

/** The detail card (Release 26): who (the full name), what they did, the score and every signal, the car with its photo,
 * the city and the time, the phone and email when "Show contact" is on, and a link into Admin. */
function PinCard({ p, now, contact, onClose, tv, portal = 'admin' }: { p: Pin; now: number; contact: boolean; onClose?: () => void; tv: boolean; portal?: 'admin' | 'staff' }) {
  const src = imgOf(p.car?.photo, 320), go = portal === 'staff' ? staffHref(p) : adminHref(p);
  return (
    <article className="lm-pop" style={{ ['--c' as string]: colourOf(p) }} aria-label={`${p.name ?? p.who}, ${TYPE[p.type].label}`} data-testid="lm-detail">
      <div className="lm-pop__top">
        <span className="lm-stage"><span className="lm-dot" aria-hidden="true" />{TYPE[p.type].label}</span>
        {onClose && <button type="button" className="lm-pop__x" onClick={onClose} aria-label="Close">×</button>}
      </div>
      <div className="lm-pop__who"><Score p={p} /><span><b data-testid="lm-detail-name">{p.name ?? p.who}</b>
        <span className="lm-quiet">{[roleLabel(p.roles), p.detail, p.city && !p.anonymous ? p.city : null].filter(Boolean).join(' · ')}</span></span></div>
      <p className="lm-pop__time">{timeLine(p, now)}</p>
      {p.signals.length > 0 && <ul className="lm-chips" aria-label="Signals">{p.signals.slice(0, 6).map((x, i) => <li key={i}><b>+{x.points}</b> {x.label}</li>)}</ul>}
      {p.car && (
        <div className="lm-pop__car">
          {/* eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized */}
          {src ? <img src={src} alt="" width={96} height={64} decoding="async" /> : <span className="lm-pop__noph"><CarShape /></span>}
          <span><span className="lm-quiet">{CAR_HOW[p.car.how] ?? 'Last viewed'}</span> {p.car.name}{p.car.daily_cents ? ` · ${money(p.car.daily_cents)}/day` : ''}</span>
        </div>
      )}
      {contact ? (p.phone || p.email) && (
        <p className="lm-pop__contact" data-testid="lm-detail-contact">
          {p.phone && (tv ? <span>{p.phone}</span> : <ContactButtons phone={p.phone} name={p.name ?? p.who} booking={p.booking_number} look="link" testId="lm-contact">{p.phone}</ContactButtons>)}{p.phone && p.email ? ' · ' : ''}{p.email && <a href={`mailto:${p.email}`}>{p.email}</a>}
        </p>) : !p.anonymous && <p className="lm-pop__hint lm-quiet">Phone and email hidden. Turn on Show contact to see them.</p>}
      {!tv && go && <p className="lm-pop__acts"><Link prefetch={false} href={go.href} data-testid="lm-detail-link">{go.label}</Link></p>}
      {tv && go && <p className="lm-pop__acts lm-quiet">{go.label.replace(/^Open /, 'In Admin: ')}</p>}
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
        case 'who': return (p.name ?? p.who).toLowerCase();
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
            const isOpen = open === p.id, href = p.booking_number ? `/admin/bookings/${encodeURIComponent(p.booking_number)}` : p.owner_id && p.roles.includes('owner') && !p.roles.includes('renter') ? `/admin/owners/${p.owner_id}` : p.renter_id ? `/admin/renters/${p.renter_id}` : null;
            return (
              <Fragment key={p.id}>
                <tr className={isOpen ? 'is-open' : undefined} style={{ ['--c' as string]: colourOf(p) }} data-testid="lm-card" data-type={p.type}>
                  <td><span className="lm-stage"><span className="lm-dot" aria-hidden="true" />{TYPE[p.type].short}</span></td>
                  <td><button type="button" className="lm-row-btn" aria-expanded={isOpen} onClick={() => setOpen(isOpen ? null : p.id)}>{p.name ?? p.who}</button></td>
                  <td className="lm-hide-s">{p.city ?? ''}</td>
                  <td className="num"><span className={`lm-n lm-n--${isLead(p) ? p.band : 'cold'}`}>{p.score}</span></td>
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
                        {href && <Link prefetch={false} href={href}>{p.booking_number ? `Open ${p.booking_number}` : href.startsWith('/admin/owners') ? 'Open the owner' : 'Open the renter'}</Link>}
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

/** 1068: the booking celebration: a pulse and confetti at the renter's place, and the toast (motion off for those who ask). */
const CONFETTI = ['var(--lm-new, #f5b301)', 'var(--lm-hot, #ff5a5f)', 'var(--lm-booked, #3ddc97)', '#5ab0ff', '#ffffff'];
function Party({ c, x, y }: { c: Celebration; x: number; y: number }) {
  return (
    <div className="lm-party" data-testid="lm-celebration">
      <div className="lm-party__at" style={{ left: x, top: y }} aria-hidden="true">
        <span className="lm-party__pulse" />
        {Array.from({ length: 18 }, (_, i) => <span key={i} className="lm-party__bit" style={{ ['--a' as string]: `${(i * 360) / 18}deg`, ['--d' as string]: `${60 + (i % 3) * 28}px`, background: CONFETTI[i % CONFETTI.length] }} />)}
      </div>
      <p className="lm-party__toast" role="status">{celebrationText(c)}</p>
    </div>
  );
}
