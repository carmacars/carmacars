'use client';
import '@/features/live-map/live-map.css';
import './tracking.css';
import Link from 'next/link';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { photoUrl } from '@/lib/photo';
import { HOME_BOUNDS, MAX_BOUNDS, inBounds, type Bounds } from '@/features/live-map/config';
import { MapEngine, type CarSpec } from '@/features/live-map/engine';
import { CAR_SILHOUETTE } from '@/features/live-map/model';
import { opsAct } from '@/server/actions/ops';
import { ALERT, STATE, ago, circle, sorted, stateLine, stateOf, when, withDemo, type CarPhoto, type Fleet, type TrackedCar, type TrackerAlert } from './model';

// Cars > Fleet tracking (migration 0400). One dark panel like the Live map: four numbers, the map with every car's photo
// marker (its ring the car's state, an arrow its heading) beside the list of cars (renter, booking, due back, state),
// then the alerts and the trips per booking. A car chosen on the map or the list opens its card and its trip's route.
// Refreshes every 15 seconds while visible; in demo mode the simulated cars move every 2 seconds in the browser.

const REFRESH_MS = 15_000, DEMO_TICK_MS = 2_000;
const imgOf = (p: CarPhoto | null | undefined, w = 160): string | null => {
  if (!p?.path || p.sample) return null;
  const v = (p.variants ?? []).filter((x) => x?.path && x.width >= w).sort((a, b) => a.width - b.width)[0];
  return photoUrl(v?.path ?? p.path);
};
type Tab = 'alerts' | 'trips';

export function FleetTracking({ initial, at, staff = false }: { initial: Fleet | null; at: number; /** the fleet staff's page: booking links go to /staff */ staff?: boolean }) {
  const [raw, setRaw] = useState<Fleet | null>(initial);
  const [now, setNow] = useState(at);
  const [err, setErr] = useState('');
  const [sel, setSel] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>('alerts');
  const [trail, setTrail] = useState<{ trip: string; path: Array<[number, number]> } | null>(null);
  const [mode, setMode] = useState<'loading' | 'map' | 'nogl'>('loading');
  const [busy, setBusy] = useState('');
  const boxRef = useRef<HTMLDivElement>(null);
  const engine = useRef<MapEngine | null>(null);
  const framed = useRef(false);
  const base = staff ? '/staff' : '/admin';

  const refresh = useCallback(async () => {
    try {
      const r = await fetch('/api/staff/tracking', { cache: 'no-store', credentials: 'same-origin' });
      const j = (await r.json()) as Fleet & { error?: string };
      if (!r.ok) throw new Error(j.error ?? 'Could not refresh');
      setRaw(j); setErr('');
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not refresh'); }
  }, []);
  useEffect(() => {
    // no first data with the page (it could not be read): ask at once, then every 15 seconds
    const first = initial ? null : setTimeout(() => void refresh(), 0);
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, REFRESH_MS);
    return () => { clearInterval(t); if (first) clearTimeout(first); };
  }, [refresh, initial]);
  // the clock: every 2 seconds in demo mode (the simulated cars move), else every 15
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), raw?.demo ? DEMO_TICK_MS : REFRESH_MS);
    return () => clearInterval(t);
  }, [raw?.demo]);

  const view = useMemo(() => (raw ? withDemo(raw, now) : null), [raw, now]);
  const cars = useMemo(() => (view ? sorted(view.cars, now) : []), [view, now]);
  const placed = useMemo(() => cars.filter((c) => c.pos && inBounds(c.pos.lng, c.pos.lat, MAX_BOUNDS)), [cars]);
  const chosen = cars.find((c) => c.vehicle_id === sel) ?? null;

  // ---------------------------------------------------------------- the map
  useEffect(() => {
    if (!boxRef.current) return;
    const e = new MapEngine(boxRef.current, { select: () => undefined, hover: () => undefined, moved: () => undefined, car: (id) => setSel(id) }, { tv: false, scale: 1 });
    engine.current = e;
    void e.start().then((m) => setMode(m));
    // the panel's grid settles after the map starts (and changes with the window): keep the map the size of its box
    const ro = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(() => e.resize());
    ro?.observe(boxRef.current);
    return () => { ro?.disconnect(); e.destroy(); engine.current = null; };
  }, []);
  useEffect(() => {
    const e = engine.current;
    if (!e || mode !== 'map') return;
    e.setCars(placed.map((c): CarSpec => {
      const s = stateOf(c, now);
      return { id: c.vehicle_id, lng: c.pos!.lng, lat: c.pos!.lat, heading: s === 'moving' ? c.pos!.heading ?? 0 : null, colour: STATE[s].colour, photo: imgOf(c.photo),
        label: `${c.name}${c.code ? ` (${c.code})` : ''}: ${stateLine(c, now)}${c.booking?.renter ? `, ${c.booking.renter}` : ''}` };
    }));
    if (!framed.current && placed.length) {
      framed.current = true;
      const b: Bounds = [...HOME_BOUNDS];
      for (const c of placed) { b[0] = Math.min(b[0], c.pos!.lng - 0.05); b[1] = Math.min(b[1], c.pos!.lat - 0.05); b[2] = Math.max(b[2], c.pos!.lng + 0.05); b[3] = Math.max(b[3], c.pos!.lat + 0.05); }
      e.frame(HOME_BOUNDS, b, { top: 24, right: 24, bottom: 24, left: 24 });
    }
  }, [placed, now, mode]);
  useEffect(() => { if (mode === 'map') engine.current?.setHq(view?.hq ?? null); }, [view?.hq, mode]);
  const st = view?.settings;
  useEffect(() => {
    if (mode !== 'map') return;
    engine.current?.setZone(st?.zone_lat != null && st.zone_lng != null && st.zone_radius_km ? circle(Number(st.zone_lat), Number(st.zone_lng), Number(st.zone_radius_km)) : null);
  }, [st?.zone_lat, st?.zone_lng, st?.zone_radius_km, mode]);
  useEffect(() => { if (mode === 'map') engine.current?.setTrail(trail?.path ?? null); }, [trail, mode]);
  useEffect(() => { engine.current?.selectCar(sel); }, [sel, mode]);

  const pick = (c: TrackedCar) => {
    setSel(c.vehicle_id);
    if (c.pos) { boxRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); engine.current?.flyTo(c.pos.lng, c.pos.lat); }
  };
  const showTrip = async (id: string) => {
    if (id.startsWith('demo-')) { setTrail(null); return; }
    try {
      const r = await fetch(`/api/staff/tracking?trip=${id}`, { cache: 'no-store', credentials: 'same-origin' });
      const j = (await r.json()) as { path?: Array<[number, number]>; error?: string };
      if (!r.ok) throw new Error(j.error ?? 'Could not read the trip');
      setTrail({ trip: id, path: j.path ?? [] });
      const p = j.path?.[Math.floor((j.path.length - 1) / 2)];
      if (p) { boxRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); engine.current?.flyTo(p[0], p[1], 10); }
    } catch (e) { setErr(e instanceof Error ? e.message : 'Could not read the trip'); }
  };
  const ack = async (a: TrackerAlert | null) => {
    setBusy(a?.id ?? 'all');
    const r = await opsAct('tracker_alert_ack', a ? { id: a.id } : { all: true });
    setBusy('');
    if (!r.ok) setErr(r.message); else void refresh();
  };

  const k = view?.counts;
  const open = (view?.alerts ?? []).filter((a) => !a.ack_at);
  const bookingHref = (n: string) => `${base}/bookings/${encodeURIComponent(n)}`;

  return (
    <div className="lm lm--page ft" data-testid="fleet-tracking">
      <div className="lm-head">
        <ul className="lm-kpis" aria-label="The fleet now" data-testid="ft-kpis">
          <li><b className="lm-kpi__v">{k?.on_rent ?? 0}</b><span className="lm-kpi__k">On rent</span></li>
          <li><b className="lm-kpi__v">{k?.moving ?? 0}</b><span className="lm-kpi__k"><span className="lm-live" aria-hidden="true" />Moving</span></li>
          <li><b className="lm-kpi__v">{k?.parked ?? 0}</b><span className="lm-kpi__k">Parked</span></li>
          <li><b className={`lm-kpi__v${open.length ? ' ft-red' : ''}`}>{open.length}</b><span className="lm-kpi__k">Open alerts</span></li>
        </ul>
        <div className="lm-head__acts">
          {view?.demo && <span className="ft-demo" data-testid="ft-demo">Demo mode: simulated cars</span>}
          <span className="lm-quiet ft-small">{k ? `${k.tracked} of ${k.cars} cars have a tracker` : ''}</span>
        </div>
      </div>

      <div className="ft-hero">
        <div className="lm-map ft-map" ref={boxRef} data-testid="ft-map" data-mode={mode}>
          {mode === 'nogl' && <p className="lm-map__note">The map needs WebGL, which this browser does not have. The list beside it has every car.</p>}
          {mode === 'map' && !placed.length && <p className="ft-empty">No car is reporting yet. Each car shows here once its tracker is paired and reports{view?.admin ? ', or turn on demo mode below to see simulated cars.' : '.'}</p>}
        </div>
        <section className="ft-list" aria-label="Cars" data-testid="ft-cars">
          <h2 className="lm-h">Cars <span>{cars.length}</span></h2>
          {chosen && <CarCard c={chosen} now={now} bookingHref={bookingHref} onClose={() => { setSel(null); setTrail(null); }} />}
          <ul>
            {cars.map((c) => {
              const s = stateOf(c, now), src = imgOf(c.photo, 96);
              return (
                <li key={c.vehicle_id}>
                  <button type="button" className={`ft-row${sel === c.vehicle_id ? ' is-sel' : ''}`} onClick={() => pick(c)} aria-pressed={sel === c.vehicle_id} data-testid="ft-car">
                    {/* eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized */}
                    <span className="ft-ph" style={{ ['--c' as string]: STATE[s].colour }}>{src ? <img src={src} alt="" decoding="async" /> : <span dangerouslySetInnerHTML={{ __html: CAR_SILHOUETTE }} />}</span>
                    <span className="ft-t">
                      <b>{c.name}</b>
                      <span className="ft-sub">{c.booking ? <>{c.booking.renter ?? 'Renter'} · {c.booking.status === 'on_rent' ? <>back {when(c.booking.return_at)}{c.booking.overdue && <em className="ft-late"> late</em>}</> : `pickup ${when(c.booking.pickup_at)}`}</> : (c.code ?? c.plate ?? 'Not on rent')}</span>
                      <span className="ft-state" style={{ ['--c' as string]: STATE[s].colour }}><span className="lm-dot" aria-hidden="true" />{stateLine(c, now)}</span>
                    </span>
                    {c.pos?.battery != null && c.pos.battery < (st?.battery_low_pct ?? 20) && <span className="ft-flag" title="Tracker battery low">{c.pos.battery}%</span>}
                  </button>
                </li>
              );
            })}
          </ul>
          {!cars.length && <p className="lm-quiet">No cars in the fleet.</p>}
        </section>
      </div>

      <div className="ft-tabs" role="tablist" aria-label="Alerts and trips">
        <button type="button" role="tab" aria-selected={tab === 'alerts'} className={tab === 'alerts' ? 'is-on' : ''} onClick={() => setTab('alerts')} data-testid="ft-tab-alerts">Alerts{open.length ? ` (${open.length})` : ''}</button>
        <button type="button" role="tab" aria-selected={tab === 'trips'} className={tab === 'trips' ? 'is-on' : ''} onClick={() => setTab('trips')} data-testid="ft-tab-trips">Trips by booking</button>
      </div>
      {tab === 'alerts' ? (
        <section className="ft-sec" aria-label="Alerts" data-testid="ft-alerts">
          {open.filter((a) => !a.demo).length > 1 && <p><button type="button" className="ft-btn" onClick={() => void ack(null)} disabled={busy === 'all'}>Mark all as seen</button></p>}
          {view?.alerts.length ? <ul className="ft-alerts">{view.alerts.map((a) => (
            <li key={a.id} className={`ft-alert ft-alert--${ALERT[a.kind].tone}${a.ack_at ? ' is-seen' : ''}`} data-testid="ft-alert">
              <span className="ft-alert__k">{ALERT[a.kind].label}{a.demo ? ' · demo' : ''}</span>
              <span className="ft-alert__t"><b>{a.title}</b><span className="ft-sub">{a.detail} {ago(a.at, now) === 'now' ? 'Just now' : `${ago(a.at, now)} ago`}{a.booking_number && <> · <Link prefetch={false} href={bookingHref(a.booking_number)}>{a.booking_number}</Link></>}</span>
                {a.ack_at && <span className="ft-sub">Seen by {a.ack_by ?? 'staff'}{a.ack_note ? `: ${a.ack_note}` : ''}</span>}</span>
              <span className="ft-alert__acts">
                {a.lat != null && a.lng != null && <button type="button" className="ft-btn ft-btn--q" onClick={() => { boxRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); engine.current?.flyTo(a.lng!, a.lat!); if (a.vehicle_id) setSel(a.vehicle_id); }}>Show</button>}
                {!a.ack_at && !a.demo && <button type="button" className="ft-btn" onClick={() => void ack(a)} disabled={busy === a.id} data-testid="ft-ack">Seen</button>}
              </span>
            </li>))}</ul> : <p className="lm-quiet">No alerts. Speeding over {st?.speed_alert_kmh ?? 140} km/h, leaving Ontario{st?.zone_name ? ` or ${st.zone_name}` : ''}, driving after the return time, a low or unplugged tracker and a tracker that stops reporting show here, in the bell and as a phone alert.</p>}
        </section>
      ) : (
        <section className="ft-sec" aria-label="Trips by booking" data-testid="ft-trips">
          {view?.bookings.length ? <div className="ft-scroll"><table className="ft-table">
            <thead><tr><th scope="col">Booking</th><th scope="col">Renter</th><th scope="col">Car</th><th scope="col" className="num">Trips</th><th scope="col" className="num">Km</th><th scope="col" className="num">Top speed</th><th scope="col">Last trip</th></tr></thead>
            <tbody>{view.bookings.map((b) => (
              <tr key={b.booking_id + (b.demo ? 'd' : '')}>
                <td><Link prefetch={false} href={bookingHref(b.number)}>{b.number}</Link>{b.demo && <span className="ft-sub"> demo</span>}</td><td>{b.renter}</td><td>{b.vehicle}</td>
                <td className="num">{b.trips}</td><td className="num">{b.km}</td>
                <td className={`num${b.max_speed && st && b.max_speed >= st.speed_alert_kmh ? ' ft-red' : ''}`}>{b.max_speed ?? ''}{b.max_speed ? ' km/h' : ''}</td>
                <td><button type="button" className="ft-link" onClick={() => void showTrip(b.list[0]!.id)} aria-pressed={trail?.trip === b.list[0]!.id}>{when(b.list[0]!.started_at)}, {b.list[0]!.km} km</button></td>
              </tr>))}</tbody></table></div>
            : <p className="lm-quiet">Trips show here per booking once the trackers report: each trip from ignition on to off, its km and top speed. Choose one to draw its route.</p>}
        </section>
      )}
      {err && <p className="lm-err" role="status">Not refreshed: {err}.</p>}
      <p className="lm-foot">Positions are seen by Admins and fleet staff only. History is kept {st?.history_days ?? 90} days, trips and alerts {st?.trip_days ?? 365} days. Basemap: Natural Earth; the GTA&apos;s highways drawn by CarmaCars.</p>
    </div>
  );
}

function CarCard({ c, now, bookingHref, onClose }: { c: TrackedCar; now: number; bookingHref: (n: string) => string; onClose: () => void }) {
  const p = c.pos, rows: Array<[string, string]> = [];
  if (p) {
    rows.push(['Last report', ago(p.at, now) === 'now' ? 'just now' : `${ago(p.at, now)} ago`]);
    if (p.odometer != null) rows.push(['Odometer', `${Math.round(p.odometer).toLocaleString('en-CA')} km`]);
    if (p.fuel != null) rows.push(['Fuel', `${p.fuel}%`]);
    if (p.battery != null) rows.push(['Tracker battery', `${p.battery}%`]);
    if (p.power != null) rows.push(['Car power', p.power ? 'Connected' : 'Unplugged']);
  }
  if (c.trip) rows.push(['This trip', `${c.trip.km} km, top ${c.trip.max ?? 0} km/h, since ${when(c.trip.started_at)}`]);
  if (c.device) rows.push(['Tracker', c.device.serial]);
  return (
    <div className="ft-card" data-testid="ft-card">
      <div className="ft-card__h"><span><b>{c.name}</b>{c.code && <span className="ft-sub"> · {c.code}</span>}</span><button type="button" className="ft-x" onClick={onClose} aria-label="Close">×</button></div>
      {c.booking && <p className="ft-sub"><Link prefetch={false} href={bookingHref(c.booking.number)}>{c.booking.number}</Link> · {c.booking.renter} · {c.booking.status === 'on_rent' ? `due back ${when(c.booking.return_at)}` : `pickup ${when(c.booking.pickup_at)}`}{c.booking.overdue && <em className="ft-late"> late</em>}</p>}
      <dl>{rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>
      {c.demo && <p className="ft-sub">Simulated (demo mode).</p>}
    </div>
  );
}
