'use client';
import Link from '@/components/Link';
import { OWNER_TRIP } from '@/features/request-history/model';
import './master-calendar.css';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useTransition } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { useDoor } from './door';
import { BAR, lane, rowHeight, stack, topOf } from './calendar-stack';
import { availability, barLabel, busyKind, holdEnds, holding, holdWords, takes, VIEWS } from './calendar-label';
import { photoUrl } from '@/lib/photo';
import { photoPath, when as nowWords, type Car } from '@/features/bookings-now/model';
import { DateInput } from '@/components/DateInput';
import { CalendarFleetBar } from './CalendarFleetBar';
import { SidePanel } from './CalendarSidePanel';
import { GROUP_H, JOB_H, NO_FILTER, VIRTUAL_FROM, chipWords, filterCount, groupCars, isCleaningJob, jobLabel, jobRows, jobsOf, passes, rowsOf, topsOf, windowOf,
  type AvailFilter, type FleetFilter, type GroupBy, type JobEntry } from './calendar-fleet';

import { WhyDisabled } from '@/components/WhyDisabled';
// The master calendar (03-admin.md section 5): vehicles as rows, days as columns. Bookings are bars by
// status (requests and offers hatched on the lower lane, non-blocking bookings outlined), blocks striped,
// Turo trips teal, jobs as small named chips under the bars (r48 ops: the Return check-out with its time and the Post-trip
// cleaning are two jobs). A long fleet is found by search, filters and groups that fold, and only the rows near the
// screen are drawn (calendar-fleet.ts). Drag or resize a booking, or move it with the keyboard (arrows 30
// minutes, Shift resizes, Enter confirms, Esc cancels); the database previews the change
// (calendar_preview_change) and applies it on confirm (calendar_apply_change).
export interface Entry { type: string; id: string; booking_id: string | null; booking_number: string | null; booking_type: string | null; status: string | null; state: string | null;
  starts_at: string; ends_at: string | null; blocks: boolean | null; blocking: boolean | null; bill_to: string | null; provisional: boolean | null; insurer: string | null;
  renter: string | null; reason: string | null; note: string | null; assignee: string | null; detail: string | null;
  /** 0283: a placeholder booking (insurance or a hold); 0284: the bars it collides with on this car */
  placeholder?: boolean; clash?: string[];
  /** r48 (2961): when an open offer expires, or an accepted unpaid booking's hold ends */
  hold_until?: string | null;
  /** r48 ops (3290): a booking's actual return and clean check; the booking a job or cleaning block belongs to; when it was done */
  returned_at?: string | null; cleaned_at?: string | null; for_booking?: string | null; done_at?: string | null; job?: string | null }
export interface Veh { id: string; label: string; plate: string | null; fleet_number: string | null; status: string; class: string | null; owner: string | null; mode: string | null; supply_type?: string | null; entries: Entry[] }
export interface CalData { from: string; to: string; now: string; vehicles: Veh[] }
type Preview = { action: string; refusal: string | null; renter_must_approve: boolean; offer_must_be_resent: boolean; available: boolean; difference_cents: number | null;
  old: { pickup_at: string; return_at: string; total_cents: number; vehicle_id: string }; new: { pickup_at: string; return_at: string; total_cents: number; vehicle_id: string } | null; conflicts: unknown[] };
type Move = { entry: Entry; vehicle: string; start: number; end: number };

const DAY = 86_400_000;
const SNAP = 30 * 60_000;
const DRAGGABLE = ['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent'];
const FLEET_KEY = 'cc-cal-fleet';
const HEAD_H = 52;
const torontoMidnight = (d: Date) => { const s = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d); return new Date(`${s}T00:00:00`); };
const isoDay = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const snap = (ms: number) => Math.round(ms / SNAP) * SNAP;

function cls(e: Entry, now: number) {
  // r44: maintenance (service, repair, cleaning) apart from the other blocks
  if (e.type === 'block') return ['service', 'repair', 'cleaning'].includes(e.reason ?? '') ? 'is-block is-maint' : 'is-block';
  if (e.type === 'turo_trip') return 'is-turo';
  if (e.type === 'field_job') return 'is-job';
  if (e.type === 'vehicle_move') return 'is-move';
  const c = [`is-${e.status}`];
  if (e.placeholder) c.push('is-placeholder');
  else if (['confirmed', 'on_rent'].includes(e.status ?? '') && e.blocks === false) c.push('is-outline');
  if (e.clash?.length) c.push('has-clash');
  if (e.booking_type === 'owner') c.push('is-owner');
  if (e.status === 'on_rent' && e.ends_at && new Date(e.ends_at).getTime() < now) c.push('is-late');
  // r48 (2961): an offer past its expiry or a hold that ran out holds nothing (the offers job closes it within minutes)
  if (holdEnds(e) !== null && !holding(e, now)) c.push('is-lapsed');
  return c.join(' ');
}
const text = (e: Entry) => e.type === 'block' ? `${(e.reason ?? '').replace(/_/g, ' ')}${e.note ? `: ${e.note}` : ''}`
  : e.type === 'booking' && e.booking_type === 'owner' ? `${OWNER_TRIP}${e.booking_number ? ` ${e.booking_number}` : ''}`
  : e.type === 'booking' ? `${e.renter?.split(' ').pop() ?? ''} ${e.status === 'requested' ? 'request' : e.status === 'offered' ? 'offer' : e.status === 'pending_payment' ? 'booked, payment due' : e.booking_number ?? ''}${e.placeholder ? ' placeholder' : e.blocks === false ? ' not blocking' : ''}${e.insurer ? ' insurer' : ''}`
  : e.type === 'turo_trip' ? 'Turo' : e.detail ?? e.type.replace(/_/g, ' ');

// Release 26 part 2 (the Now view's look): each car row starts with its photo, code and plate (cars, from car_thumbs,
// 0332); the bars keep the Now colours (out red, booked black, requests and offers hatched, placeholders dashed, a red
// ring and "!" where the dates are taken); the phone agenda is grouped by day; a bar opens a side panel.
const dayHead = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(iso));
const hm = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)).replace(/\s?a\.m\./, ' am').replace(/\s?p\.m\./, ' pm');
const WORDS: Record<string, string> = { requested: 'Request', offered: 'Offer', pending_payment: 'Booked, payment due', confirmed: 'Booked', on_rent: 'Out', returned: 'Returned', closed: 'Closed' };
const kindOf = (e: Entry) => isCleaningJob(e) ? 'Post-trip cleaning' : e.type === 'booking' ? (e.placeholder ? 'Placeholder' : WORDS[e.status ?? ''] ?? (e.status ?? '').replace(/_/g, ' ')) : e.type === 'block' ? 'Block' : e.type === 'turo_trip' ? 'Turo' : e.type.replace(/_/g, ' ');

function Label({ e }: { e: Entry }) {
  const l = barLabel(e);
  return l.main || l.sub ? <span className="mcal__lbl"><b>{l.main}</b><small>{l.sub}</small></span> : null;
}

function Thumb({ car, label }: { car?: Car; label: string }) {
  const p = photoPath(car?.photo, 96);
  // eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized (0149's variants)
  return p ? <img className="mcal__thumb" src={photoUrl(p)} alt="" width={44} height={30} loading="lazy" decoding="async" /> : <span className="mcal__thumb mcal__thumb--none" aria-hidden="true">{(label.replace(/^\d{4}\s+/, '')[0] ?? '?').toUpperCase()}</span>;
}

export function MasterCalendar({ initial, vehicleId, defaultView = 'two', vehicleLinks = true, cars = {}, initialAgenda = false }: { initial: CalData; vehicleId?: string; defaultView?: string; vehicleLinks?: boolean; cars?: Record<string, Car>; initialAgenda?: boolean }) {
  const { act: adminAct, preview: adminPreview, base: doorBase } = useDoor();
  const router = useRouter();
  const sp = useSearchParams();
  const [data, setData] = useState(initial);
  const [view, setView] = useState(sp.get('view') ?? defaultView);
  const [q, setQ] = useState(sp.get('q') ?? '');
  const [onlyNonBlocking, setOnlyNonBlocking] = useState(sp.get('nb') === '1');
  const [onlyInsurer, setOnlyInsurer] = useState(sp.get('ins') === '1');
  const [onlyFree, setOnlyFree] = useState(sp.get('free') === '1'); // r48: only cars free every day shown
  const [supply, setSupply] = useState(sp.get('supply') ?? ''); // 0046: who supplies the car
  // r48 ops: the long fleet: filters, groups that fold (kept in this browser), and the rows near the screen
  const [filter, setFilter] = useState<FleetFilter>(() => ({ status: sp.get('status') ?? '', cls: sp.get('class') ?? '', owner: sp.get('owner') ?? '', avail: (sp.get('avail') ?? '') as AvailFilter }));
  const [groupBy, setGroupByState] = useState<GroupBy>((sp.get('group') as GroupBy | null) ?? 'none');
  const [folded, setFolded] = useState<ReadonlySet<string>>(() => new Set());
  const [scroll, setScroll] = useState({ top: 0, h: 800 });
  const [heights, setHeights] = useState<ReadonlyMap<string, number>>(() => new Map());
  const [agenda, setAgenda] = useState(initialAgenda);
  const [sel, setSel] = useState<{ entry?: Entry; job?: JobEntry; vehicle?: Veh; at?: number } | null>(null);
  const [move, setMove] = useState<Move | null>(null);
  const [confirm, setConfirm] = useState<{ move: Move; preview: Preview | null; error?: string } | null>(null);
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState('');
  const [pending, start] = useTransition();
  const [problem, setProblem] = useState<string | null>(null);
  const grid = useRef<HTMLDivElement>(null);
  const drag = useRef<{ entry: Entry; mode: 'move' | 'resize'; x0: number; y0: number; s0: number; e0: number; vehicle: string; moved: boolean } | null>(null);
  const { days, dw } = VIEWS[view] ?? VIEWS.two!;
  const from = new Date(data.from).getTime();
  const now = new Date(data.now).getTime();
  const pxPerMs = dw / DAY;

  useEffect(() => { const t = setTimeout(() => { if (window.matchMedia('(max-width: 40rem)').matches) setAgenda(true); }, 0); return () => clearTimeout(t); }, []);
  // the grouping chosen last time, and the groups left folded (this browser only; the link's ?group= wins)
  useEffect(() => {
    const t = setTimeout(() => {
      try {
        const k = JSON.parse(window.localStorage.getItem(FLEET_KEY) ?? 'null') as { by?: GroupBy; folded?: string[] } | null;
        if (!k) return;
        if (k.by && !sp.get('group')) setGroupByState(k.by);
        if (Array.isArray(k.folded)) setFolded(new Set(k.folded));
      } catch { /* private window: this page only */ }
    }, 0);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- read once
  }, []);
  const keep = (by: GroupBy, f: ReadonlySet<string>) => { try { window.localStorage.setItem(FLEET_KEY, JSON.stringify({ by, folded: [...f] })); } catch { /* this page only */ } };
  const setGroupBy = (by: GroupBy) => { const f = new Set<string>(); setGroupByState(by); setFolded(f); keep(by, f); };
  const fold = (key: string) => setFolded((old) => { const f = new Set(old); if (f.has(key)) f.delete(key); else f.add(key); keep(groupBy, f); return f; });

  const load = useCallback((startAt: Date, v = view) => start(async () => {
    const f = torontoMidnight(startAt); const t = new Date(f.getTime() + (VIEWS[v] ?? VIEWS.two!).days * DAY);
    const r = await adminPreview<CalData>('calendar', { from: f.toISOString(), to: t.toISOString(), vehicle: vehicleId ?? '' });
    if (r.ok) { setData(r.data); setProblem(null); setHeights(new Map()); } else setProblem(r.message);
    const p = new URLSearchParams(sp.toString()); p.set('start', isoDay(f)); p.set('view', v);
    router.replace(`?${p.toString()}`, { scroll: false });
  }), [view, vehicleId, router, sp, adminPreview]);
  const shift = (n: number) => load(new Date(from + n * DAY));

  // by calendar day, not 24 hours at a time: on the night the clocks go back 24 hours later is still the same date ("1 Nov" twice)
  const dayList = useMemo(() => Array.from({ length: days }, (_, i) => { const d = new Date(from); d.setDate(d.getDate() + i); return d; }), [from, days]);
  const todayStart = torontoMidnight(new Date(now)).getTime();
  // r48: each car's availability, now and over the days shown from today on (calendar-label.ts)
  const avail = useMemo(() => {
    const ranges = dayList.map((d) => { const e = new Date(d); e.setDate(e.getDate() + 1); return [d.getTime(), e.getTime()] as [number, number]; });
    return new Map(data.vehicles.map((v) => [v.id, availability(v, now, ranges, todayStart)]));
  }, [data, dayList, now, todayStart]);
  const matching = useMemo(() => data.vehicles.filter((v) => {
    const s = q.trim().toLowerCase();
    const hit = !s || [v.label, v.plate, v.fleet_number].some((x) => x?.toLowerCase().includes(s)) || v.entries.some((e) => [e.booking_number, e.renter].some((x) => x?.toLowerCase().includes(s)));
    const nb = !onlyNonBlocking || v.entries.some((e) => e.type === 'booking' && e.blocks === false);
    const ins = !onlyInsurer || v.entries.some((e) => e.bill_to && e.bill_to !== 'renter');
    const sup = !supply || (v.supply_type ?? 'program_owner') === supply;
    return hit && nb && ins && sup && passes(v, avail.get(v.id), filter);
  }), [data, q, onlyNonBlocking, onlyInsurer, supply, filter, avail]);
  const vehicles = useMemo(() => onlyFree ? matching.filter((v) => avail.get(v.id)?.freeAll) : matching, [matching, onlyFree, avail]);
  const freeToday = matching.filter((v) => avail.get(v.id)?.freeToday).length;
  const dirty = !!q.trim() || onlyFree || onlyNonBlocking || onlyInsurer || !!supply || filterCount(filter) > 0;
  const clear = () => { setQ(''); setOnlyFree(false); setOnlyNonBlocking(false); setOnlyInsurer(false); setSupply(''); setFilter(NO_FILTER); };
  // each car's row: its bars stacked, its jobs as chips under them, and the height that takes
  const layout = useMemo(() => new Map(vehicles.map((v) => {
    const end = from + days * DAY;
    const st = stack(v.entries.filter((e) => !isCleaningJob(e)), end);
    const jobs = jobsOf(v.entries).filter((j) => { const t = Date.parse(j.starts_at); return t >= from && t < end; });
    const jr = jobRows(jobs, (iso) => (Date.parse(iso) - from) * pxPerMs, days * dw);
    return [v.id, { st, jobs, jr, height: rowHeight(st) + (jr.rows ? jr.rows * JOB_H + 8 : 0) }] as const;
  })), [vehicles, from, days, dw, pxPerMs]);
  const groups = useMemo(() => groupCars(vehicles, vehicleId ? 'none' : groupBy, (id) => avail.get(id)), [vehicles, groupBy, avail, vehicleId]);
  const rows = useMemo(() => rowsOf(groups, folded), [groups, folded]);
  const named = groups.filter((g) => g.key);
  const virtual = rows.length > VIRTUAL_FROM;
  const tops = topsOf(rows.map((r) => r.kind === 'group' ? GROUP_H : heights.get(r.key) ?? (layout.get(r.key)?.height ?? 62) + 1));
  const win = virtual ? windowOf(tops, Math.max(0, scroll.top - HEAD_H), scroll.h) : { start: 0, end: rows.length, before: 0, after: 0 };
  const onScroll = (ev: React.UIEvent<HTMLDivElement>) => {
    if (!virtual) return;
    const g = ev.currentTarget; const top = g.scrollTop, h = g.clientHeight;
    setScroll((o) => (Math.abs(o.top - top) > 160 || o.h !== h ? { top, h } : o));
  };
  // the window follows where the list really is whenever the list becomes long again or its length changes: a scroll that
  // happened while the list was short (a search, a filter) is not reported by onScroll, and a stale position would draw rows far from the top
  useLayoutEffect(() => {
    const g = grid.current;
    if (!virtual || !g) return;
    setScroll((o) => (Math.abs(o.top - g.scrollTop) > 160 || o.h !== g.clientHeight ? { top: g.scrollTop, h: g.clientHeight } : o));
  }, [virtual, rows.length]);
  // a drawn row's real height (a long name or badge can make it taller than its bars): kept, so the space of the rows
  // not drawn is right and the list does not jump
  useLayoutEffect(() => {
    if (!virtual || !grid.current) return;
    let next: Map<string, number> | null = null;
    for (const el of grid.current.querySelectorAll<HTMLElement>('[data-row]')) {
      const h = el.offsetHeight, k = el.dataset.row!;
      if (h && Math.abs((heights.get(k) ?? 0) - h) > 0.5) { next ??= new Map(heights); next.set(k, h); }
    }
    if (next) setHeights(next);
  }, [virtual, heights, win.start, win.end, rows, view]);

  const preview = (m: Move) => {
    setConfirm({ move: m, preview: null }); setReason(''); setMsg('');
    start(async () => {
      const changes: Record<string, string> = { pickup_at: new Date(m.start).toISOString(), return_at: new Date(m.end).toISOString() };
      if (m.vehicle !== m.entry.id && m.vehicle) changes.vehicle_id = m.vehicle;
      const r = await adminPreview<Preview>('calendar_preview', { booking: m.entry.booking_id, changes });
      setConfirm({ move: m, preview: r.ok ? r.data : null, error: r.ok ? undefined : r.message });
    });
  };
  const vehicleOf = (e: Entry) => data.vehicles.find((v) => v.entries.some((x) => x.id === e.id && x.type === e.type))?.id ?? '';

  // pointer drag on a booking bar or its resize grip
  const onDown = (ev: React.PointerEvent, e: Entry, mode: 'move' | 'resize') => {
    if (e.type !== 'booking' || !DRAGGABLE.includes(e.status ?? '') || !e.ends_at) return;
    if (e.status === 'on_rent' && mode === 'move') return;
    ev.stopPropagation();
    (ev.target as HTMLElement).setPointerCapture?.(ev.pointerId);
    drag.current = { entry: e, mode, x0: ev.clientX, y0: ev.clientY, s0: new Date(e.starts_at).getTime(), e0: new Date(e.ends_at).getTime(), vehicle: vehicleOf(e), moved: false };
  };
  const onMoveP = (ev: React.PointerEvent) => {
    const d = drag.current; if (!d) return;
    const dx = ev.clientX - d.x0;
    if (!d.moved && Math.abs(dx) < 4 && Math.abs(ev.clientY - d.y0) < 4) return;
    d.moved = true;
    const delta = snap(dx / pxPerMs);
    let vehicle = d.vehicle;
    if (d.mode === 'move') {
      const el = document.elementsFromPoint(ev.clientX, ev.clientY).find((x) => (x as HTMLElement).dataset?.vehicle) as HTMLElement | undefined;
      if (el?.dataset.vehicle) vehicle = el.dataset.vehicle;
    }
    setMove(d.mode === 'move' ? { entry: d.entry, vehicle, start: d.s0 + delta, end: d.e0 + delta } : { entry: d.entry, vehicle, start: d.s0, end: Math.max(d.s0 + SNAP, d.e0 + delta) });
  };
  const onUp = () => {
    const d = drag.current; drag.current = null;
    if (!d) return;
    if (!d.moved) { setSel({ entry: d.entry }); return; }
    if (move && (move.start !== d.s0 || move.end !== d.e0 || move.vehicle !== d.vehicle)) preview({ ...move, vehicle: move.vehicle === d.vehicle ? '' : move.vehicle });
    else setMove(null);
  };
  const onKey = (ev: React.KeyboardEvent, e: Entry) => {
    if (ev.key === 'Enter' && !move) { setSel({ entry: e }); return; }
    if (e.type !== 'booking' || !DRAGGABLE.includes(e.status ?? '') || !e.ends_at) return;
    const base = move && move.entry.id === e.id ? move : { entry: e, vehicle: '', start: new Date(e.starts_at).getTime(), end: new Date(e.ends_at).getTime() };
    const step = ev.key === 'ArrowRight' ? SNAP : ev.key === 'ArrowLeft' ? -SNAP : 0;
    if (step) { ev.preventDefault(); setMove(ev.shiftKey || e.status === 'on_rent' ? { ...base, end: Math.max(base.start + SNAP, base.end + step) } : { ...base, start: base.start + step, end: base.end + step }); }
    if (ev.key === 'Enter' && move) { ev.preventDefault(); preview(move); }
    if (ev.key === 'Escape') setMove(null);
  };
  const cancel = () => { setConfirm(null); setMove(null); };
  useEffect(() => { const k = (e: KeyboardEvent) => { if (e.key === 'Escape') { setConfirm(null); setMove(null); setSel(null); } if (e.key === 't' && !(e.target as HTMLElement).closest('input,textarea,select')) load(new Date()); }; window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k); }, [load]);

  const apply = () => {
    if (!confirm?.preview || !reason.trim()) return;
    const m = confirm.move;
    start(async () => {
      const changes: Record<string, string> = { pickup_at: new Date(m.start).toISOString(), return_at: new Date(m.end).toISOString() };
      if (m.vehicle) changes.vehicle_id = m.vehicle;
      const r = await adminAct('calendar_apply', { booking: m.entry.booking_id, changes, reason: reason.trim(), message: msg.trim() || null }, ['/admin/calendar']);
      if (!r.ok) { setConfirm({ ...confirm, error: r.message }); return; }
      setConfirm(null); setMove(null); load(new Date(from));
    });
  };

  const pos = (s: number, e: number) => ({ left: Math.max(0, (s - from) * pxPerMs), width: Math.max(6, (Math.min(e, from + days * DAY) - Math.max(s, from)) * pxPerMs) });
  const width = `calc(var(--namew) + ${days * dw}px)`;
  const cols = `var(--namew) ${days * dw}px`;
  const todayIdx = dayList.findIndex((d) => isoDay(d) === isoDay(torontoMidnight(new Date(now))));

  return (
    <div className="mcal" data-testid="master-calendar">
      <div className="mcal__bar">
        <div className="row">
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => shift(-Math.max(1, Math.floor(days / 2)))} aria-label="Earlier">←</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => load(new Date())}>Today</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => shift(Math.max(1, Math.floor(days / 2)))} aria-label="Later">→</button>
          <label className="vh" htmlFor="cal-start">Start date</label>
          <DateInput className="input" style={{ minHeight: 36, width: '10rem' }} id="cal-start" type="date" value={isoDay(new Date(from))} onChange={(e) => e.target.value && load(new Date(`${e.target.value}T12:00:00`))} />
          <label className="vh" htmlFor="cal-view">View</label>
          <select className="select" style={{ minHeight: 36, width: 'auto' }} id="cal-view" value={view} onChange={(e) => { setView(e.target.value); load(new Date(from), e.target.value); }}>
            {Object.entries(VIEWS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</select>
          <button className="btn btn--ghost btn--sm" type="button" aria-pressed={agenda} onClick={() => setAgenda(!agenda)}>{agenda ? 'Timeline' : 'Agenda'}</button>
        </div>
        <div className="row mcal__find">
          <label className="vh" htmlFor="cal-q">Find a plate, fleet number, booking or surname</label>
          <input className="input" id="cal-q" type="search" placeholder="Car, plate, booking, surname" value={q} onChange={(e) => setQ(e.target.value)} data-shortcut="/" enterKeyHint="search" />
          <label className="check small"><input type="checkbox" checked={onlyFree} onChange={(e) => setOnlyFree(e.target.checked)} data-testid="cal-only-free" /> <span>Only cars free for these dates</span></label>
          <button className="btn btn--primary btn--sm" type="button" onClick={() => setSel({ vehicle: vehicles[0], at: Math.max(now, from) })} data-testid="cal-new-block">New block</button>
        </div>
        {!vehicleId && <CalendarFleetBar cars={data.vehicles} filter={filter} onFilter={setFilter} groupBy={groupBy} onGroupBy={setGroupBy} shown={vehicles.length} freeToday={freeToday} groups={named.length}
          allFolded={named.length > 0 && named.every((g) => folded.has(g.key))} onFoldAll={(f) => { const n = new Set(f ? named.map((g) => g.key) : []); setFolded(n); keep(groupBy, n); }} onClear={clear} dirty={dirty} />}
        {!vehicleId && <details className="ad-morefilters mcal__more"><summary>More filters</summary>
          <div className="row">
            <label className="check small"><input type="checkbox" checked={onlyNonBlocking} onChange={(e) => setOnlyNonBlocking(e.target.checked)} /> <span>Not blocking</span></label>
            <label className="check small"><input type="checkbox" checked={onlyInsurer} onChange={(e) => setOnlyInsurer(e.target.checked)} /> <span>Insurer</span></label>
            <label className="vh" htmlFor="cal-supply">Who supplies the car</label>
            <select className="select" id="cal-supply" value={supply} onChange={(e) => setSupply(e.target.value)} data-testid="cal-supply">
              <option value="">Every car</option><option value="program_owner">Program owners&apos; cars</option><option value="company">Company fleet</option><option value="partner">Partners&apos; cars</option></select>
          </div></details>}
      </div>
      {problem && <p className="alert alert--error" role="alert"><span>{problem}</span></p>}
      <div className="mcal__legend" aria-hidden="true">
        <span><i className="mcal__swatch is-free" /> white: free</span><span><i className="mcal__swatch is-taken" /> tinted: taken</span><span><i className="mcal__swatch is-hold" /> hatched: held until the offer or payment time ends</span><span><i className="mcal__swatch is-off" /> not bookable</span>
        <span><i className="mcal__item is-on_rent" /> on rent</span><span><i className="mcal__item is-confirmed" /> confirmed</span><span><i className="mcal__item is-requested" /> request</span>
        <span><i className="mcal__item is-offered" /> offer or hold</span><span><i className="mcal__item is-block is-maint" /> maintenance</span><span><i className="mcal__item is-confirmed is-outline" /> not blocking</span><span><i className="mcal__item is-confirmed is-placeholder" /> placeholder</span><span><i className="mcal__item is-block" /> block</span>
        <span><i className="mcal__item is-requested has-clash" /> dates taken</span><span><i className="mcal__item is-turo" /> Turo</span>
        <span><i className="mcal__job is-checkout" /> return check-out, with its time</span><span><i className="mcal__job is-cleaning" /> post-trip cleaning</span>
      </div>
      {agenda ? (
        <div className="mcal__agenda" data-testid="cal-agenda">
          {(() => {
            // r48 ops: the bars, and the jobs by name (the return check-out with its time, the post-trip cleaning)
            const end = from + days * DAY;
            const items: Array<{ v: Veh; e?: Entry; j?: JobEntry; at: string }> = vehicles.flatMap((v) => [
              ...v.entries.filter((e) => e.type !== 'field_job' && !isCleaningJob(e)).map((e) => ({ v, e, at: e.starts_at })),
              ...jobsOf(v.entries).filter((j) => { const t = Date.parse(j.starts_at); return t >= from && t < end; }).map((j) => ({ v, j, at: j.starts_at }))])
              .sort((a, b) => a.at.localeCompare(b.at));
            if (!items.length) return <p className="mcal__none">{dirty ? 'No car matches the search and filters.' : 'Nothing on the calendar for these dates.'}</p>;
            const days_: Array<[string, typeof items]> = [];
            for (const it of items) { const k = dayHead(it.at); const g = days_[days_.length - 1]; if (g && g[0] === k) g[1].push(it); else days_.push([k, [it]]); }
            return days_.map(([k, list]) => (
              <section key={k} className="mcal__aday"><h3>{k}</h3>
                <ul>{list.map(({ v, e, j }) => {
                  if (j) { const l = jobLabel(j); const src = j.type === 'block' ? v.entries.find((x) => x.type === 'block' && x.id === j.id) : undefined; return (
                    <li key={`job${j.type}${j.id}`}><button type="button" className="mcal__acard" data-kind={`job-${l.kind}`} onClick={() => setSel(src ? { entry: src } : { job: j })} data-testid={`agenda-job-${l.kind}`}>
                      <span className="mcal__atime"><b>{hm(l.done && j.done_at ? j.done_at : j.starts_at)}</b><span>{l.done ? (l.kind === 'checkout' ? 'came back' : 'done') : 'due'}</span></span>
                      <Thumb car={cars[v.id]} label={v.label} />
                      <span className="mcal__abody"><b>{v.label}</b><span>{[cars[v.id]?.code, v.plate, j.for_booking, j.assignee].filter(Boolean).join(' · ')}</span>{j.type === 'block' && j.note ? <span>{j.note}</span> : null}</span>
                      <span className={`mcal__akind mcal__job is-${l.kind}${l.done ? ' is-done' : ''}`}>{l.name}</span>
                    </button></li>); }
                  if (!e) return null;
                  return (
                  <li key={`${e.type}${e.id}`}><button type="button" className="mcal__acard" data-kind={e.type === 'booking' ? (e.placeholder ? 'placeholder' : e.status ?? '') : e.type} data-clash={e.clash?.length ? 'yes' : undefined} onClick={() => setSel({ entry: e })}>
                    <span className="mcal__atime"><b>{hm(e.starts_at)}</b>{e.ends_at ? <span>to {nowWords(e.returned_at ?? e.ends_at, now)}</span> : null}</span>
                    <Thumb car={cars[v.id]} label={v.label} />
                    <span className="mcal__abody"><b>{v.label}</b><span>{[cars[v.id]?.code, v.plate].filter(Boolean).join(' · ')}{e.renter ? ` · ${e.renter}` : ''}{e.booking_number ? ` · ${e.booking_number}` : ''}</span>
                      {e.type !== 'booking' && <span>{text(e)}</span>}
                      {e.clash?.length ? <b className="ad-late" data-testid="cal-agenda-clash">Dates taken: clashes with {e.clash.join(', ')}</b> : null}</span>
                    <span className={`mcal__akind mcal__item ${cls(e, now).replace('has-clash', '').replace('is-late', '')}`}>{kindOf(e)}</span>
                  </button></li>); })}</ul>
              </section>));
          })()}
        </div>
      ) : (
        <div className="mcal__grid" ref={grid} onPointerMove={onMoveP} onPointerUp={onUp} onScroll={onScroll} aria-label="Vehicles by day" role="region" tabIndex={0} data-virtual={virtual ? 'yes' : undefined} data-rows={rows.length}>
          <div className="mcal__inner" style={{ width, ['--dw' as string]: `${dw}px` }}>
            <div className="mcal__head" style={{ gridTemplateColumns: cols }}>
              <div className="mcal__corner"><b>{new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', year: 'numeric' }).format(new Date(from))}</b><span data-testid="cal-free-count">{freeToday} of {matching.length} free today</span></div>
              <div className="mcal__days" style={{ width: days * dw }}>
                {dayList.map((d, i) => { const td = i === todayIdx; const we = d.getDay() === 0 || d.getDay() === 6; return (
                  <div key={d.toISOString()} className={`mcal__day${td ? ' is-today' : ''}${we ? ' is-weekend' : ''}`} style={{ left: i * dw, width: dw }} aria-current={td ? 'date' : undefined}>
                    {/* the 1st of a month says the month where the weekday goes; the corner names the first month */}
                    <span className={i > 0 && d.getDate() === 1 ? 'mcal__wd mcal__mo' : 'mcal__wd'}>{new Intl.DateTimeFormat('en-CA', i > 0 && d.getDate() === 1 ? { month: 'short' } : { weekday: 'short' }).format(d).replace('.', '')}</span><b>{d.getDate()}</b></div>); })}
              </div>
            </div>
            {vehicles.length === 0 && <div className="mcal__empty" data-testid="cal-empty"><p className="ad-empty">{dirty ? 'No car matches the search and filters.' : 'No vehicles match.'}</p>
              {dirty && <button className="btn btn--ghost btn--sm" type="button" onClick={clear}>Clear the search and filters</button>}</div>}
            {win.before > 0 && <div style={{ height: win.before }} aria-hidden="true" />}
            {rows.slice(win.start, win.end).map((r) => { if (r.kind === 'group') return (
              <div key={r.key} className="mcal__group" data-row={r.key} data-testid="cal-group-row">
                <button type="button" className="mcal__gbtn" aria-expanded={r.open} onClick={() => fold(r.key.slice(2))} data-testid={`cal-group-${r.label}`}>
                  <svg viewBox="0 0 20 20" width="16" height="16" aria-hidden="true"><path d="M7.5 4l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
                  <b>{r.label}</b><span>{r.count} {r.count === 1 ? 'car' : 'cars'} · {r.free} free today</span></button>
              </div>);
              const v = r.car; const L = layout.get(v.id)!; const st = L.st; const a = avail.get(v.id)!; return (
              <div key={v.id} className={`mcal__row${a.kind === 'off' ? ' is-off' : ''}`} style={{ gridTemplateColumns: cols }} data-avail={a.kind} data-free-all={a.freeAll ? 'yes' : undefined} data-row={v.id}>
                <div className="mcal__name" title={[v.label, v.plate, a.now, a.window].filter(Boolean).join(' · ')}><Thumb car={cars[v.id]} label={v.label} /><span className="mcal__ntext">{vehicleLinks ? <Link prefetch={false} href={`${doorBase}/vehicles/${v.id}`}>{v.label}</Link> : <b>{v.label}</b>}<span>{[cars[v.id]?.code ?? v.fleet_number, v.plate].filter(Boolean).join(' · ')}{v.status !== 'available' && a.kind !== 'off' ? <span className="mcal__status"> · {v.status.replace(/_/g, ' ')}</span> : null}</span>
                  <span className={`mcal__avail is-${a.kind}`} data-testid="cal-avail">{a.now}</span>{a.window ? <small className="mcal__win">{a.window}</small> : null}</span></div>
                <div className={`mcal__lane${move && (move.vehicle || vehicleOf(move.entry)) === v.id ? ' is-drop' : ''}`} data-vehicle={v.id} data-testid={`lane-${v.plate ?? v.id}`} data-rows={st.top + st.low}
                  style={{ minHeight: L.height }}
                  onDoubleClick={(ev) => { const r = (ev.currentTarget as HTMLElement).getBoundingClientRect(); setSel({ vehicle: v, at: snap(from + (ev.clientX - r.left) / pxPerMs) }); }}>
                  {/* r48: what takes the car, tinted across the row, so white is free */}
                  {v.entries.filter(takes).map((e) => { const s0 = Date.parse(e.starts_at); const e0 = e.ends_at ? Date.parse(e.ends_at) : from + days * DAY;
                    if (e0 <= from || s0 >= from + days * DAY) return null; const p = pos(s0, e0);
                    return <span key={`busy${e.type}${e.id}`} className={`mcal__busy is-${busyKind(e)}`} style={{ left: p.left, width: p.width }} aria-hidden="true" />; })}
                  {/* r48 (2961): an open offer or an accepted booking not paid yet, a light hatched hold until it ends */}
                  {v.entries.filter((e) => holding(e, now)).map((e) => { const s0 = Date.parse(e.starts_at); const e0 = e.ends_at ? Date.parse(e.ends_at) : from + days * DAY;
                    if (e0 <= from || s0 >= from + days * DAY) return null; const p = pos(s0, e0);
                    return <span key={`hold${e.id}`} className="mcal__busy is-hold" style={{ left: p.left, width: p.width }} aria-hidden="true" data-testid="cal-hold" />; })}
                  {now >= from && now <= from + days * DAY && <span className="mcal__now" style={{ left: (now - from) * pxPerMs }} aria-hidden="true" />}
                  {v.entries.map((e) => {
                    // r48 ops: field jobs and the post-trip cleaning are named chips under the bars (below)
                    if (e.type === 'field_job' || isCleaningJob(e)) return null;
                    const s = new Date(e.starts_at).getTime(); const en = e.ends_at ? new Date(e.ends_at).getTime() : from + days * DAY;
                    const m = move && move.entry.id === e.id && move.entry.type === e.type ? move : null;
                    if (m && m.vehicle && m.vehicle !== v.id) return null;
                    const p = pos(m ? m.start : s, m ? m.end : en);
                    const canDrag = e.type === 'booking' && DRAGGABLE.includes(e.status ?? '');
                    const bar = e.type === 'booking' || e.type === 'block';
                    const clash = e.clash?.length ? `. Clashes with ${e.clash.join(', ')}` : '';
                    return (
                      <div key={`${e.type}${e.id}`} role="button" tabIndex={0} data-testid={e.booking_number ? `bar-${e.booking_number}` : `item-${e.type}`}
                        className={`mcal__item mcal__item--${lane(e)} ${cls(e, now)}${m ? ' is-dragging' : ''}`} style={{ left: p.left, width: p.width, ...(bar ? { top: topOf(e, st) } : {}) }}
                        data-clash={e.clash?.length ? e.clash.join(',') : undefined}
                        title={`${text(e)} · ${when(e.starts_at)}${e.ends_at ? ` to ${when(e.ends_at)}` : ''}${e.returned_at ? ` · came back ${when(e.returned_at)}` : ''}${holdWords(e, now) ? ` · ${holdWords(e, now)}` : ''}${clash}`}
                        aria-label={`${text(e)}, ${when(e.starts_at)}${e.ends_at ? ` to ${when(e.ends_at)}` : ''}${holdWords(e, now) ? `. ${holdWords(e, now)}` : ''}${clash}${canDrag ? '. Arrow keys move, Shift and arrows resize, Enter confirms' : ''}`}
                        data-hold={holdEnds(e) !== null ? (holding(e, now) ? 'on' : 'ended') : undefined}
                        onPointerDown={(ev) => onDown(ev, e, 'move')} onClick={() => { if (!canDrag) setSel({ entry: e }); }} onKeyDown={(ev) => onKey(ev, e)}>
                        {p.width >= 28 && <Label e={e} />}
                        {canDrag && <span className="mcal__grip" aria-hidden="true" onPointerDown={(ev) => onDown(ev, e, 'resize')} />}
                      </div>);
                  })}
                  {move && move.vehicle === v.id && (() => { const e = move.entry; const p = pos(move.start, move.end); return <div className={`mcal__item mcal__item--${lane(e)} ${cls(e, now)} is-dragging`} style={{ left: p.left, width: p.width, ...(e.type === 'booking' ? { top: 4 + BAR * (lane(e) === 'top' ? 0 : 1) } : {}) }} aria-hidden="true"><Label e={e} /></div>; })()}
                  {L.jobs.map((j) => { const at = L.jr.at.get(`${j.type}${j.id}`); if (!at) return null; const l = jobLabel(j);
                    const src = j.type === 'block' ? v.entries.find((x) => x.type === 'block' && x.id === j.id) : undefined;
                    return (
                      <button key={`job${j.type}${j.id}`} type="button" className={`mcal__job is-${l.kind}${l.done ? ' is-done' : ''}`} style={{ left: at.left, width: at.width, bottom: 8 + at.row * JOB_H }}
                        title={`${l.full}${j.for_booking ? ` · ${j.for_booking}` : ''}${j.assignee ? ` · ${j.assignee}` : ''}`} data-testid={j.type === 'field_job' ? 'item-field_job' : `job-${l.kind}`} data-job={l.kind} data-done={l.done ? 'yes' : undefined}
                        onClick={(ev) => { ev.stopPropagation(); setSel(src ? { entry: src } : { job: j }); }} onDoubleClick={(ev) => ev.stopPropagation()}>{chipWords(l)}</button>); })}
                </div>
              </div>
            ); })}
            {win.after > 0 && <div style={{ height: win.after }} aria-hidden="true" />}
          </div>
        </div>
      )}

      {confirm && (
        <div className="mcal__panel" role="dialog" aria-modal="true" aria-labelledby="cal-confirm-t" data-testid="cal-confirm">
          <h2 className="d4" id="cal-confirm-t">Move {confirm.move.entry.booking_number}?</h2>
          {!confirm.preview && !confirm.error && <p className="small">Checking with the database.</p>}
          {confirm.error && <p className="alert alert--error" role="alert"><span>{confirm.error}</span></p>}
          {confirm.preview && (
            <>
              <dl className="pt-dl small">
                <div><dt>Was</dt><dd>{when(confirm.preview.old.pickup_at)} to {when(confirm.preview.old.return_at)}</dd></div>
                <div><dt>Now</dt><dd>{when(new Date(confirm.move.start).toISOString())} to {when(new Date(confirm.move.end).toISOString())}</dd></div>
                {confirm.move.vehicle && <div><dt>Car</dt><dd>{data.vehicles.find((v) => v.id === confirm.move.vehicle)?.label}</dd></div>}
                {confirm.preview.new && <div><dt>Price</dt><dd data-testid="cal-price">{money(confirm.preview.old.total_cents, { cents: true })} to {money(confirm.preview.new.total_cents, { cents: true })} ({(confirm.preview.difference_cents ?? 0) >= 0 ? '+' : ''}{money(confirm.preview.difference_cents ?? 0, { cents: true })})</dd></div>}
                <div><dt>Car free</dt><dd>{confirm.preview.available ? 'Yes' : 'No'}</dd></div>
              </dl>
              {confirm.preview.refusal && <p className="alert alert--error" role="alert"><span>{confirm.preview.refusal}</span></p>}
              {confirm.preview.offer_must_be_resent && <p className="pt-note small">An offer is out. This withdraws it and sends a new version.</p>}
              {confirm.preview.renter_must_approve && <p className="pt-note small" data-testid="cal-renter-approval">The renter must approve this change. Nothing moves until they agree.</p>}
              {!confirm.preview.refusal && (
                <form className="ad-form" onSubmit={(e) => { e.preventDefault(); apply(); }}>
                  <div className="field"><label className="label" htmlFor="cal-reason">Reason</label><input className="input" id="cal-reason" value={reason} onChange={(e) => setReason(e.target.value)} required autoFocus /></div>
                  {(confirm.preview.renter_must_approve || confirm.preview.offer_must_be_resent) && <div className="field"><label className="label" htmlFor="cal-msg">Message to the renter</label><textarea className="input ad-textarea" id="cal-msg" value={msg} onChange={(e) => setMsg(e.target.value)} /></div>}
                  <div className="row"><><button className="btn btn--primary btn--sm" type="submit" disabled={pending || !reason.trim()} data-testid="cal-apply" aria-describedby="why-mastercalendar-339">{pending ? 'Working' : 'Confirm the move'}</button><WhyDisabled id="why-mastercalendar-339" why={((!reason.trim())) ? 'Write the reason first' : null} /></><button className="btn btn--ghost btn--sm" type="button" onClick={cancel}>Cancel</button></div>
                </form>
              )}
            </>
          )}
          {(confirm.error || confirm.preview?.refusal) && <button className="btn btn--ghost btn--sm" type="button" onClick={cancel}>Close</button>}
        </div>
      )}
      {sel && !confirm && <SidePanel sel={sel} vehicles={data.vehicles} onClose={() => setSel(null)} onDone={() => { setSel(null); load(new Date(from)); }} />}
    </div>
  );
}
