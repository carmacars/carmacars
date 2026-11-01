'use client';
import Link from 'next/link';
import '@/features/bookings-now/bookings-now.css';
import { useCallback, useEffect, useMemo, useRef, useState, useTransition } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { useDoor } from './door';
import { toLocalInput } from './Act';
import { lane, rowHeight, stack, topOf } from './calendar-stack';
import { photoUrl } from '@/lib/photo';
import { photoPath, when as nowWords, type Car } from '@/features/bookings-now/model';

// The master calendar (03-admin.md section 5): vehicles as rows, days as columns. Bookings are bars by
// status (requests and offers hatched on the lower lane, non-blocking bookings outlined), blocks striped,
// Turo trips teal, field jobs as pins. Drag or resize a booking, or move it with the keyboard (arrows 30
// minutes, Shift resizes, Enter confirms, Esc cancels); the database previews the change
// (calendar_preview_change) and applies it on confirm (calendar_apply_change).
export interface Entry { type: string; id: string; booking_id: string | null; booking_number: string | null; booking_type: string | null; status: string | null; state: string | null;
  starts_at: string; ends_at: string | null; blocks: boolean | null; blocking: boolean | null; bill_to: string | null; provisional: boolean | null; insurer: string | null;
  renter: string | null; reason: string | null; note: string | null; assignee: string | null; detail: string | null;
  /** 0283: a placeholder booking (insurance or a hold); 0284: the bars it collides with on this car */
  placeholder?: boolean; clash?: string[] }
export interface Veh { id: string; label: string; plate: string | null; fleet_number: string | null; status: string; class: string | null; owner: string | null; mode: string | null; supply_type?: string | null; entries: Entry[] }
export interface CalData { from: string; to: string; now: string; vehicles: Veh[] }
type Preview = { action: string; refusal: string | null; renter_must_approve: boolean; offer_must_be_resent: boolean; available: boolean; difference_cents: number | null;
  old: { pickup_at: string; return_at: string; total_cents: number; vehicle_id: string }; new: { pickup_at: string; return_at: string; total_cents: number; vehicle_id: string } | null; conflicts: unknown[] };
type Move = { entry: Entry; vehicle: string; start: number; end: number };

const DAY = 86_400_000;
const SNAP = 30 * 60_000;
const DRAGGABLE = ['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent'];
const VIEWS: Record<string, { days: number; dw: number; label: string }> = { week: { days: 7, dw: 120, label: 'Week' }, two: { days: 14, dw: 72, label: '2 weeks' }, month: { days: 31, dw: 38, label: 'Month' } };
const REASONS: Array<[string, string]> = [['service', 'Service'], ['repair', 'Repair'], ['owner_unavailable', 'Owner unavailable'], ['cleaning', 'Cleaning'], ['exit', 'Exit'], ['turo_owner_use', 'Turo owner use'], ['admin', 'Admin']];
const torontoMidnight = (d: Date) => { const s = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d); return new Date(`${s}T00:00:00`); };
const isoDay = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const snap = (ms: number) => Math.round(ms / SNAP) * SNAP;

function cls(e: Entry, now: number) {
  if (e.type === 'block') return 'is-block';
  if (e.type === 'turo_trip') return 'is-turo';
  if (e.type === 'field_job') return 'is-job';
  if (e.type === 'vehicle_move') return 'is-move';
  const c = [`is-${e.status}`];
  if (e.placeholder) c.push('is-placeholder');
  else if (['confirmed', 'on_rent'].includes(e.status ?? '') && e.blocks === false) c.push('is-outline');
  if (e.clash?.length) c.push('has-clash');
  if (e.booking_type === 'owner') c.push('is-owner');
  if (e.status === 'on_rent' && e.ends_at && new Date(e.ends_at).getTime() < now) c.push('is-late');
  return c.join(' ');
}
const text = (e: Entry) => e.type === 'block' ? `${(e.reason ?? '').replace(/_/g, ' ')}${e.note ? `: ${e.note}` : ''}`
  : e.type === 'booking' ? `${e.renter?.split(' ').pop() ?? ''} ${e.status === 'requested' ? 'request' : e.status === 'offered' ? 'offer' : e.status === 'pending_payment' ? 'signing and payment' : e.booking_number ?? ''}${e.placeholder ? ' placeholder' : e.blocks === false ? ' not blocking' : ''}${e.insurer ? ' insurer' : ''}`
  : e.type === 'turo_trip' ? 'Turo' : e.detail ?? e.type.replace(/_/g, ' ');

// Release 26 part 2 (the Now view's look): each car row starts with its photo, code and plate (cars, from car_thumbs,
// 0332); the bars keep the Now colours (out red, booked black, requests and offers hatched, placeholders dashed, a red
// ring and "!" where the dates are taken); the phone agenda is grouped by day; a bar opens a side panel.
const dayHead = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric' }).format(new Date(iso));
const hm = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)).replace(/\s?a\.m\./, ' am').replace(/\s?p\.m\./, ' pm');
const WORDS: Record<string, string> = { requested: 'Request', offered: 'Offer', pending_payment: 'Waiting for payment', confirmed: 'Booked', on_rent: 'Out', returned: 'Returned', closed: 'Closed' };
const kindOf = (e: Entry) => e.type === 'booking' ? (e.placeholder ? 'Placeholder' : WORDS[e.status ?? ''] ?? (e.status ?? '').replace(/_/g, ' ')) : e.type === 'block' ? 'Block' : e.type === 'turo_trip' ? 'Turo' : e.type.replace(/_/g, ' ');

function Thumb({ car, label }: { car?: Car; label: string }) {
  const p = photoPath(car?.photo, 96);
  // eslint-disable-next-line @next/next/no-img-element -- the listing photos come pre-sized (0149's variants)
  return p ? <img className="cal__thumb" src={photoUrl(p)} alt="" width={44} height={30} loading="lazy" decoding="async" /> : <span className="cal__thumb cal__thumb--none" aria-hidden="true">{(label.replace(/^\d{4}\s+/, '')[0] ?? '?').toUpperCase()}</span>;
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
  const [supply, setSupply] = useState(sp.get('supply') ?? ''); // 0046: who supplies the car
  const [agenda, setAgenda] = useState(initialAgenda);
  const [sel, setSel] = useState<{ entry?: Entry; vehicle?: Veh; at?: number } | null>(null);
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

  const load = useCallback((startAt: Date, v = view) => start(async () => {
    const f = torontoMidnight(startAt); const t = new Date(f.getTime() + (VIEWS[v] ?? VIEWS.two!).days * DAY);
    const r = await adminPreview<CalData>('calendar', { from: f.toISOString(), to: t.toISOString(), vehicle: vehicleId ?? '' });
    if (r.ok) { setData(r.data); setProblem(null); } else setProblem(r.message);
    const p = new URLSearchParams(sp.toString()); p.set('start', isoDay(f)); p.set('view', v);
    router.replace(`?${p.toString()}`, { scroll: false });
  }), [view, vehicleId, router, sp, adminPreview]);
  const shift = (n: number) => load(new Date(from + n * DAY));

  const vehicles = useMemo(() => data.vehicles.filter((v) => {
    const s = q.trim().toLowerCase();
    const hit = !s || [v.label, v.plate, v.fleet_number].some((x) => x?.toLowerCase().includes(s)) || v.entries.some((e) => [e.booking_number, e.renter].some((x) => x?.toLowerCase().includes(s)));
    const nb = !onlyNonBlocking || v.entries.some((e) => e.type === 'booking' && e.blocks === false);
    const ins = !onlyInsurer || v.entries.some((e) => e.bill_to && e.bill_to !== 'renter');
    const sup = !supply || (v.supply_type ?? 'program_owner') === supply;
    return hit && nb && ins && sup;
  }), [data, q, onlyNonBlocking, onlyInsurer, supply]);

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
  // by calendar day, not 24 hours at a time: on the night the clocks go back 24 hours later is still the same date ("1 Nov" twice)
  const dayList = Array.from({ length: days }, (_, i) => { const d = new Date(from); d.setDate(d.getDate() + i); return d; });
  const width = `calc(14rem + ${days * dw}px)`;

  return (
    <div className="cal" data-testid="master-calendar">
      <div className="cal__bar">
        <div className="row">
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => shift(-Math.max(1, Math.floor(days / 2)))} aria-label="Earlier">←</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => load(new Date())}>Today</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => shift(Math.max(1, Math.floor(days / 2)))} aria-label="Later">→</button>
          <label className="vh" htmlFor="cal-start">Start date</label>
          <input className="input" style={{ minHeight: 36, width: '10rem' }} id="cal-start" type="date" value={isoDay(new Date(from))} onChange={(e) => e.target.value && load(new Date(`${e.target.value}T12:00:00`))} />
          <label className="vh" htmlFor="cal-view">View</label>
          <select className="select" style={{ minHeight: 36, width: 'auto' }} id="cal-view" value={view} onChange={(e) => { setView(e.target.value); load(new Date(from), e.target.value); }}>
            {Object.entries(VIEWS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</select>
          <button className="btn btn--ghost btn--sm" type="button" aria-pressed={agenda} onClick={() => setAgenda(!agenda)}>{agenda ? 'Timeline' : 'Agenda'}</button>
        </div>
        <div className="row">
          <label className="vh" htmlFor="cal-q">Find a plate, fleet number, booking or surname</label>
          <input className="input" style={{ minHeight: 36, width: '13rem' }} id="cal-q" type="search" placeholder="Plate, booking, surname" value={q} onChange={(e) => setQ(e.target.value)} data-shortcut="/" />
          <label className="check small"><input type="checkbox" checked={onlyNonBlocking} onChange={(e) => setOnlyNonBlocking(e.target.checked)} /> <span>Not blocking</span></label>
          <label className="check small"><input type="checkbox" checked={onlyInsurer} onChange={(e) => setOnlyInsurer(e.target.checked)} /> <span>Insurer</span></label>
          <label className="vh" htmlFor="cal-supply">Who supplies the car</label>
          <select className="select" style={{ width: 'auto', minHeight: 0 }} id="cal-supply" value={supply} onChange={(e) => setSupply(e.target.value)} data-testid="cal-supply">
            <option value="">Every car</option><option value="program_owner">Program owners&apos; cars</option><option value="company">Company fleet</option><option value="partner">Partners&apos; cars</option></select>
          <button className="btn btn--primary btn--sm" type="button" onClick={() => setSel({ vehicle: vehicles[0], at: Math.max(now, from) })} data-testid="cal-new-block">New block</button>
        </div>
      </div>
      {problem && <p className="alert alert--error" role="alert"><span>{problem}</span></p>}
      <div className="cal__legend" aria-hidden="true">
        <span><i className="cal__item is-on_rent" /> out</span><span><i className="cal__item is-confirmed" /> booked</span><span><i className="cal__item is-requested" /> request</span>
        <span><i className="cal__item is-offered" /> offer</span><span><i className="cal__item is-confirmed is-outline" /> not blocking</span><span><i className="cal__item is-confirmed is-placeholder" /> placeholder</span><span><i className="cal__item is-block" /> block</span>
        <span><i className="cal__item is-requested has-clash" /> dates taken</span><span><i className="cal__item" style={{ background: '#0f7b6c' }} /> Turo</span>
      </div>
      {agenda ? (
        <div className="cal__agenda" data-testid="cal-agenda">
          {(() => {
            const items = vehicles.flatMap((v) => v.entries.map((e) => ({ v, e }))).sort((a, b) => a.e.starts_at.localeCompare(b.e.starts_at));
            if (!items.length) return <p className="cal__none">Nothing on the calendar for these dates.</p>;
            const groups: Array<[string, typeof items]> = [];
            for (const it of items) { const k = dayHead(it.e.starts_at); const g = groups[groups.length - 1]; if (g && g[0] === k) g[1].push(it); else groups.push([k, [it]]); }
            return groups.map(([k, rows]) => (
              <section key={k} className="cal__aday"><h3>{k}</h3>
                <ul>{rows.map(({ v, e }) => (
                  <li key={`${e.type}${e.id}`}><button type="button" className="cal__acard" data-kind={e.type === 'booking' ? (e.placeholder ? 'placeholder' : e.status ?? '') : e.type} data-clash={e.clash?.length ? 'yes' : undefined} onClick={() => setSel({ entry: e })}>
                    <span className="cal__atime"><b>{hm(e.starts_at)}</b>{e.ends_at ? <span>to {nowWords(e.ends_at, now)}</span> : null}</span>
                    <Thumb car={cars[v.id]} label={v.label} />
                    <span className="cal__abody"><b>{v.label}</b><span>{[cars[v.id]?.code, v.plate].filter(Boolean).join(' · ')}{e.renter ? ` · ${e.renter}` : ''}{e.booking_number ? ` · ${e.booking_number}` : ''}</span>
                      {e.clash?.length ? <b className="ad-late" data-testid="cal-agenda-clash">Dates taken: clashes with {e.clash.join(', ')}</b> : null}</span>
                    <span className={`cal__akind cal__item ${cls(e, now).replace('has-clash', '').replace('is-late', '')}`}>{kindOf(e)}</span>
                  </button></li>))}</ul>
              </section>));
          })()}
        </div>
      ) : (
        <div className="cal__grid" ref={grid} onPointerMove={onMoveP} onPointerUp={onUp} aria-label="Vehicles by day" role="region" tabIndex={0}>
          <div className="cal__inner" style={{ width, ['--dw' as string]: `${dw}px` }}>
            <div className="cal__head" style={{ gridTemplateColumns: `14rem ${days * dw}px` }}>
              <div className="cal__corner">{vehicles.length} vehicles</div>
              <div className="cal__days" style={{ width: days * dw }}>
                {dayList.map((d, i) => { const td = isoDay(d) === isoDay(torontoMidnight(new Date(now))); const we = d.getDay() === 0 || d.getDay() === 6; return (
                  <div key={d.toISOString()} className={`cal__day${td ? ' is-today' : ''}${we ? ' is-weekend' : ''}`} style={{ left: i * dw, width: dw }}><b>{d.getDate()}</b>{new Intl.DateTimeFormat('en-CA', { weekday: 'short', month: dw > 60 ? 'short' : undefined }).format(d)}</div>); })}
              </div>
            </div>
            {vehicles.length === 0 && <p className="ad-empty">No vehicles match.</p>}
            {vehicles.map((v) => { const st = stack(v.entries, from + days * DAY); return (
              <div key={v.id} className="cal__row" style={{ gridTemplateColumns: `14rem ${days * dw}px` }}>
                <div className="cal__name"><Thumb car={cars[v.id]} label={v.label} /><span className="cal__ntext">{vehicleLinks ? <Link prefetch={false} href={`${doorBase}/vehicles/${v.id}`}>{v.label}</Link> : <b>{v.label}</b>}<span>{[cars[v.id]?.code ?? v.fleet_number, v.plate].filter(Boolean).join(' · ')}{v.status !== 'available' ? ` · ${v.status.replace(/_/g, ' ')}` : ''}</span></span></div>
                <div className={`cal__lane${move && (move.vehicle || vehicleOf(move.entry)) === v.id ? ' is-drop' : ''}`} data-vehicle={v.id} data-testid={`lane-${v.plate ?? v.id}`} data-rows={st.top + st.low}
                  style={st.top + st.low > 2 ? { height: rowHeight(st) } : undefined}
                  onDoubleClick={(ev) => { const r = (ev.currentTarget as HTMLElement).getBoundingClientRect(); setSel({ vehicle: v, at: snap(from + (ev.clientX - r.left) / pxPerMs) }); }}>
                  {now >= from && now <= from + days * DAY && <span className="cal__now" style={{ left: (now - from) * pxPerMs }} aria-hidden="true" />}
                  {v.entries.map((e) => {
                    const s = new Date(e.starts_at).getTime(); const en = e.ends_at ? new Date(e.ends_at).getTime() : from + days * DAY;
                    const m = move && move.entry.id === e.id && move.entry.type === e.type ? move : null;
                    if (m && m.vehicle && m.vehicle !== v.id) return null;
                    const p = pos(m ? m.start : s, m ? m.end : (e.type === 'field_job' ? s + 3600_000 : en));
                    const canDrag = e.type === 'booking' && DRAGGABLE.includes(e.status ?? '');
                    const bar = e.type === 'booking' || e.type === 'block';
                    const clash = e.clash?.length ? `. Clashes with ${e.clash.join(', ')}` : '';
                    return (
                      <div key={`${e.type}${e.id}`} role="button" tabIndex={0} data-testid={e.booking_number ? `bar-${e.booking_number}` : `item-${e.type}`}
                        className={`cal__item cal__item--${lane(e)} ${cls(e, now)}${m ? ' is-dragging' : ''}`} style={{ left: p.left, width: p.width, ...(bar ? { top: topOf(e, st) } : {}) }}
                        data-clash={e.clash?.length ? e.clash.join(',') : undefined}
                        title={`${text(e)} · ${when(e.starts_at)}${e.ends_at ? ` to ${when(e.ends_at)}` : ''}${clash}`}
                        aria-label={`${text(e)}, ${when(e.starts_at)}${e.ends_at ? ` to ${when(e.ends_at)}` : ''}${clash}${canDrag ? '. Arrow keys move, Shift and arrows resize, Enter confirms' : ''}`}
                        onPointerDown={(ev) => onDown(ev, e, 'move')} onClick={() => { if (!canDrag) setSel({ entry: e }); }} onKeyDown={(ev) => onKey(ev, e)}>
                        {text(e)}
                        {canDrag && <span className="cal__grip" aria-hidden="true" onPointerDown={(ev) => onDown(ev, e, 'resize')} />}
                      </div>);
                  })}
                  {move && move.vehicle === v.id && (() => { const e = move.entry; const p = pos(move.start, move.end); return <div className={`cal__item cal__item--${lane(e)} ${cls(e, now)} is-dragging`} style={{ left: p.left, width: p.width }} aria-hidden="true">{text(e)}</div>; })()}
                </div>
              </div>
            ); })}
          </div>
        </div>
      )}

      {confirm && (
        <div className="cal__panel" role="dialog" aria-modal="true" aria-labelledby="cal-confirm-t" data-testid="cal-confirm">
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
                  <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending || !reason.trim()} data-testid="cal-apply">{pending ? 'Working' : 'Confirm the move'}</button><button className="btn btn--ghost btn--sm" type="button" onClick={cancel}>Cancel</button></div>
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

function SidePanel({ sel, vehicles, onClose, onDone }: { sel: { entry?: Entry; vehicle?: Veh; at?: number }; vehicles: Veh[]; onClose: () => void; onDone: () => void }) {
  const { act: adminAct, base } = useDoor();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [conflicts, setConflicts] = useState<Array<{ booking_number: string }> | null>(null);
  const [f, setF] = useState(() => ({ vehicle: sel.vehicle?.id ?? vehicles[0]?.id ?? '', reason: 'service', starts_at: toLocalInput(new Date(sel.at ?? Date.now()).toISOString()), ends_at: toLocalInput(new Date((sel.at ?? Date.now()) + DAY).toISOString()), note: '', remove: '' }));
  const e = sel.entry;
  const run = (action: string, p: Record<string, unknown>) => start(async () => {
    setErr(null);
    const r = await adminAct<{ conflicts?: Array<{ booking_number: string }>; id?: string }>(action, p, ['/admin/calendar']);
    if (!r.ok) { setErr(r.message); return; }
    if (action === 'block_create' && !r.data.id && r.data.conflicts?.length) { setConflicts(r.data.conflicts); return; }
    onDone();
  });
  const blockBody = (force = false) => ({ vehicle: f.vehicle, reason: f.reason, starts_at: new Date(f.starts_at).toISOString(), ends_at: f.ends_at ? new Date(f.ends_at).toISOString() : null, note: f.note, force });
  return (
    <div className="cal__panel" role="dialog" aria-labelledby="cal-side-t" data-testid="cal-panel">
      <div className="row" style={{ justifyContent: 'space-between' }}><h2 className="d4" id="cal-side-t">{e ? (e.type === 'booking' ? e.booking_number : e.type === 'block' ? 'Calendar block' : e.type.replace(/_/g, ' ')) : 'New block'}</h2><button className="btn btn--quiet btn--sm" type="button" onClick={onClose}>Close</button></div>
      {e && (
        <dl className="pt-dl small">
          <div><dt>From</dt><dd>{when(e.starts_at)}</dd></div><div><dt>To</dt><dd>{e.ends_at ? when(e.ends_at) : 'until further notice'}</dd></div>
          {e.status && <div><dt>Status</dt><dd>{e.status.replace(/_/g, ' ')}{e.placeholder ? ', placeholder (never blocks, never handed over, never matched to a toll)' : e.blocks === false ? ', not blocking' : ''}</dd></div>}
          {!!e.clash?.length && <div><dt>Dates taken</dt><dd className="ad-late" data-testid="cal-clash">Clashes with {e.clash.join(', ')}{e.type === 'booking' && !['confirmed', 'on_rent'].includes(e.status ?? '') ? ': offer another car or other dates' : ''}</dd></div>}
          {e.renter && <div><dt>Renter</dt><dd>{e.renter}</dd></div>}
          {e.insurer && <div><dt>Insurer</dt><dd>{e.insurer}{e.provisional ? ', dates provisional' : ''}</dd></div>}
          {e.reason && <div><dt>Reason</dt><dd>{e.reason.replace(/_/g, ' ')}</dd></div>}
          {e.note && <div><dt>Note</dt><dd>{e.note}</dd></div>}
          {e.assignee && <div><dt>Assigned</dt><dd>{e.assignee}</dd></div>}
        </dl>
      )}
      {e?.type === 'booking' && <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/bookings/${e.booking_number}`}>Open the booking</Link>}
      {e?.type === 'block' && (
        <div className="stack">
          <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => run('block_end', { block: e.id })}>End now</button>
          {/* the cleaning block after a trip (migration 0040) is removed by Fleet, customer service or an Admin; it is not put back */}
          {e.reason === 'cleaning' && (e.note ?? '').startsWith('Cleaning after booking') && <p className="small muted" data-testid="cleaning-block">Added after the trip for cleaning. Remove it if the car is ready sooner.</p>}
          <form className="ad-form" onSubmit={(ev) => { ev.preventDefault(); run(e.reason === 'cleaning' && (e.note ?? '').startsWith('Cleaning after booking') ? 'turnaround_block_remove' : 'block_remove', { block: e.id, reason: f.remove }); }}>
            <div className="field"><label className="label" htmlFor="cal-rm">Reason for removing</label><input className="input" id="cal-rm" value={f.remove} onChange={(x) => setF({ ...f, remove: x.target.value })} required /></div>
            <button className="btn btn--primary btn--sm ad-btn--danger" type="submit" disabled={pending || !f.remove.trim()} data-testid="block-remove">Remove the block</button>
          </form>
        </div>
      )}
      {!e && (
        <form className="ad-form" data-testid="block-form" onSubmit={(ev) => { ev.preventDefault(); run('block_create', blockBody()); }}>
          <div className="field"><label className="label" htmlFor="bk-v">Vehicle</label><select className="select" id="bk-v" value={f.vehicle} onChange={(x) => setF({ ...f, vehicle: x.target.value })}>{vehicles.map((v) => <option key={v.id} value={v.id}>{v.label} {v.plate ?? ''}</option>)}</select></div>
          <div className="field"><label className="label" htmlFor="bk-r">Reason</label><select className="select" id="bk-r" value={f.reason} onChange={(x) => setF({ ...f, reason: x.target.value })}>{REASONS.map(([a, b]) => <option key={a} value={a}>{b}</option>)}</select></div>
          <div className="field"><label className="label" htmlFor="bk-s">From</label><input className="input" id="bk-s" type="datetime-local" value={f.starts_at} onChange={(x) => setF({ ...f, starts_at: x.target.value })} required /></div>
          <div className="field"><label className="label" htmlFor="bk-e">To (empty: until further notice)</label><input className="input" id="bk-e" type="datetime-local" value={f.ends_at} onChange={(x) => setF({ ...f, ends_at: x.target.value })} /></div>
          <div className="field"><label className="label" htmlFor="bk-n">Note{f.reason === 'admin' ? ' (required)' : ''}</label><input className="input" id="bk-n" value={f.note} onChange={(x) => setF({ ...f, note: x.target.value })} /></div>
          {conflicts && <div className="ow-warn small"><b>Confirmed bookings in this range:</b> {conflicts.map((c) => c.booking_number).join(', ')}. Creating anyway raises an urgent fleet task for each.
            <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => run('block_create', blockBody(true))}>Create anyway</button></div>}
          <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="block-create">{pending ? 'Working' : 'Create the block'}</button>
        </form>
      )}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
    </div>
  );
}
