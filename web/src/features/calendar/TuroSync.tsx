'use client';
import Link from 'next/link';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { calendarAct, type CalendarAction } from '@/server/actions/calendar-sync';
import { torontoToUtc } from '@/features/turo/email';

// Turo by email on Calendar sync (migration 0063). Turo has no calendar link, so:
//   in:  Turo's trip emails, forwarded from rent@carmacars.ca to the inbound address, block the car (per car: the name
//        Turo gives it, so the emails can be matched); unclear emails wait in a short review list; a trip can be added by hand
//   out: Turo cannot read our calendar either, so each CarmaCars booking is blocked on Turo by hand and ticked "Done on Turo"
export interface TuroTrip { id: string; trip_id: string; starts_at: string; ends_at: string; guest_first_name: string | null; source: 'email' | 'manual'; last_kind: string; blocked: boolean }
export interface TuroBlock { booking_id: string; booking_number: string; starts_at: string; ends_at: string; was?: { starts_at: string; ends_at: string } | null }
export interface TuroFree { booking_id: string; booking_number: string; starts_at: string; ends_at: string; why: string }
export interface TuroCarData { id: string; name: string; turo: { link: { listing_name: string | null; turo_vehicle_id: string | null } | null; trips: TuroTrip[]; block: TuroBlock[]; free: TuroFree[] } }
export interface TuroReview { id: string; received_at: string; subject: string | null; kind: string; reason: string | null; trip_id: string | null; vehicle_id: string | null; vehicle: string | null;
  vehicle_hint: string | null; starts_at: string | null; ends_at: string | null; guest_first_name: string | null; excerpt: string | null }
export interface TuroData {
  enabled: boolean; address: string; forwarders: string; admin: boolean; last_email_at: string | null; emails_7d: number;
  confirmation: { id: string; code: string; url: string | null; received_at: string } | null;
  review: TuroReview[]; log: Array<{ id: string; received_at: string; kind: string; status: string; method: string; audit: string | null; reason: string | null }>;
}

const at = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' }) : 'never');
const STATUS: Record<string, string> = { applied: 'Done', review: 'To check', ignored: 'Ignored', notice: 'Gmail', resolved: 'Checked', dismissed: 'Dismissed' };
// a datetime-local value (Toronto time) as UTC
const utc = (v: string) => { const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(v); return m ? torontoToUtc(+m[1]!, +m[2]!, +m[3]!, +m[4]!, +m[5]!).toISOString() : ''; };
const local = (iso: string | null) => {
  if (!iso) return '';
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
    .formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
};

function useAct(onDone: (m: string) => void) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const act = (a: CalendarAction, p: Record<string, unknown>, msg: string, after?: () => void) => start(async () => {
    setErr(null);
    const r = await calendarAct(a, p);
    if (!r.ok) setErr(r.message ?? 'That did not work.'); else { after?.(); onDone(msg); }
  });
  return { pending, err, act };
}

/** Add a Turo trip by hand (or the trip of an email under review). */
export function TripForm({ cars, carId, email, initial, onDone }: { cars?: Array<{ id: string; name: string }>; carId?: string; email?: string;
  initial?: { trip_id?: string | null; starts_at?: string | null; ends_at?: string | null; guest_first_name?: string | null; vehicle_id?: string | null }; onDone: (m: string) => void }) {
  const [vehicle, setVehicle] = useState(carId ?? initial?.vehicle_id ?? '');
  const [trip, setTrip] = useState(initial?.trip_id ?? '');
  const [from, setFrom] = useState(local(initial?.starts_at ?? null));
  const [to, setTo] = useState(local(initial?.ends_at ?? null));
  const [guest, setGuest] = useState(initial?.guest_first_name ?? '');
  const { pending, err, act } = useAct(onDone);
  const id = (email ?? carId ?? 'x').slice(0, 8);
  return (
    <form className="cs-add" data-testid="turo-trip-form" onSubmit={(e) => {
      e.preventDefault();
      act('turo_trip_add', { vehicle, trip_id: trip.trim() || null, starts_at: utc(from), ends_at: utc(to), guest_first_name: guest.trim() || null, email: email ?? null },
        email ? 'Trip added and the email checked' : 'Turo trip added: the car is blocked');
    }}>
      <div className="cs-trip__fields">
        {cars && <div className="field"><label className="label" htmlFor={`tc-${id}`}>Car</label>
          <select className="select" id={`tc-${id}`} required value={vehicle} onChange={(e) => setVehicle(e.target.value)}>
            <option value="">Choose the car</option>{cars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></div>}
        <div className="field"><label className="label" htmlFor={`tf-${id}`}>Trip start (Toronto time)</label>
          <input className="input" id={`tf-${id}`} type="datetime-local" required value={from} onChange={(e) => setFrom(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor={`tt-${id}`}>Trip end</label>
          <input className="input" id={`tt-${id}`} type="datetime-local" required value={to} onChange={(e) => setTo(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor={`tn-${id}`}>Turo trip number (optional)</label>
          <input className="input" id={`tn-${id}`} inputMode="numeric" maxLength={20} value={trip} onChange={(e) => setTrip(e.target.value)} placeholder="48211907" /></div>
        <div className="field"><label className="label" htmlFor={`tg-${id}`}>Guest first name (optional)</label>
          <input className="input" id={`tg-${id}`} maxLength={40} value={guest} onChange={(e) => setGuest(e.target.value)} /></div>
      </div>
      <button type="submit" className="btn btn--primary btn--sm" disabled={pending || !vehicle || !from || !to}>{pending ? 'Adding' : email ? 'Add this trip' : 'Add the trip'}</button>
      {err && <p className="small ad-late" role="alert">{err}</p>}
    </form>
  );
}

/** The page's Turo card: how the emails arrive, Gmail's confirmation code, the emails to check, the last emails. */
export function TuroPanel({ turo, cars }: { turo: TuroData; cars: Array<{ id: string; name: string }> }) {
  const router = useRouter();
  const [msg, setMsg] = useState<string | null>(null);
  const done = (m: string) => { setMsg(m); router.refresh(); };
  const { pending, err, act } = useAct(done);
  const [open, setOpen] = useState<string | null>(null);
  return (
    <section className="pt-card ad-card cs-turo" id="turo" aria-labelledby="turo-h" data-testid="turo-panel">
      <h2 className="d4" id="turo-h">Turo by email</h2>
      <p className="small">Turo has no calendar link. Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled; a Gmail
        filter forwards those emails to <b>{turo.address}</b> and each one blocks the car here within a minute (the turnaround included).
        {turo.enabled ? '' : ' Turo by email is turned off in Program settings.'}</p>
      <p className="small muted" data-testid="turo-last">{turo.last_email_at ? `Last Turo email ${at(turo.last_email_at)} · ${turo.emails_7d} in 7 days` : 'No Turo email received yet. Set up the Gmail filter (Guide, Calendar sync).'}</p>
      {turo.confirmation && (
        <div className="cs-confirm" role="status" data-testid="gmail-confirmation">
          <p className="small"><b>Gmail forwarding confirmation</b> received {at(turo.confirmation.received_at)}. Confirmation code: <b className="num">{turo.confirmation.code}</b></p>
          <p className="small">In Gmail (rent@carmacars.ca), Settings, Forwarding and POP/IMAP: type this code and press Verify{turo.confirmation.url ? <>, or <a className="link" href={turo.confirmation.url} target="_blank" rel="noopener noreferrer">open Gmail&apos;s confirmation link</a></> : ''}.</p>
          <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => act('turo_confirmation_dismiss', { id: turo.confirmation!.id }, 'Hidden')}>Done, hide this</button>
        </div>
      )}
      <div id="turo-review" data-testid="turo-review">
        <h3 className="cs-h">Turo emails to check ({turo.review.length})</h3>
        {turo.review.length ? (
          <ul className="cs-feeds">{turo.review.map((r) => (
            <li key={r.id} className="cs-feed" data-testid="turo-review-item">
              <div className="cs-feed__head"><b>{r.subject ?? 'No subject'}</b> <span className="badge badge--red">To check</span> <span className="small muted">{at(r.received_at)}</span></div>
              <p className="small">{r.reason}. Read: {[r.kind, r.trip_id && `trip ${r.trip_id}`, r.vehicle ?? (r.vehicle_hint && `"${r.vehicle_hint}"`), r.starts_at && `${at(r.starts_at)} to ${at(r.ends_at)}`, r.guest_first_name].filter(Boolean).join(', ')}</p>
              {r.excerpt && <p className="small muted cs-excerpt">{r.excerpt}</p>}
              <div className="row cs-actions">
                <button type="button" className="btn btn--primary btn--sm" onClick={() => setOpen(open === r.id ? null : r.id)} aria-expanded={open === r.id}>Add as a Turo trip</button>
                <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => act('turo_review_dismiss', { id: r.id }, 'Dismissed')}>Dismiss</button>
              </div>
              {open === r.id && <TripForm cars={cars} email={r.id} initial={r} onDone={done} />}
            </li>))}</ul>
        ) : <p className="small muted">Nothing to check. An email the reader is not sure about (which car, the dates, the trip number) waits here.</p>}
      </div>
      {turo.log.length > 0 && (
        <details className="todo__clear"><summary className="small muted">Last emails ({turo.log.length})</summary>
          <ul className="small cs-log" data-testid="turo-log">{turo.log.map((l) => (
            <li key={l.id}><span className="muted">{at(l.received_at)}</span> {STATUS[l.status] ?? l.status}{l.method === 'ai' ? ' (read with the assistant)' : ''}: {l.audit ?? l.reason}</li>))}</ul>
          <p className="small muted">Only what was read is kept (the car, dates, trip number, the guest&apos;s first name), never the email itself. The log is kept 90 days.</p>
        </details>)}
      {err && <p className="small ad-late" role="alert">{err}</p>}
      {msg && <p className="small" role="status" data-testid="turo-msg">{msg}</p>}
    </section>
  );
}

/** One car's Turo part: the name Turo gives it, its Turo trips, a trip by hand, and our bookings to block on Turo. */
export function TuroCar({ car, enabled, bookingBase, onDone }: { car: TuroCarData; enabled: boolean; bookingBase: string; onDone: (m: string) => void }) {
  const link = car.turo.link;
  const [edit, setEdit] = useState(false);
  const [name, setName] = useState(link?.listing_name ?? '');
  const [num, setNum] = useState(link?.turo_vehicle_id ?? '');
  const [add, setAdd] = useState(false);
  const { pending, err, act } = useAct(onDone);
  const id = car.id.slice(0, 8);
  return (
    <div className="cs-turocar" data-testid={`turo-car-${car.id}`}>
      <h3 className="cs-h">Turo</h3>
      {!link && !edit && (
        <p className="small muted">Not set up for Turo. <button type="button" className="btn btn--quiet btn--sm" onClick={() => setEdit(true)}>This car is on Turo</button></p>
      )}
      {edit ? (
        <form className="cs-add" onSubmit={(e) => { e.preventDefault(); act('turo_link_save', { vehicle: car.id, listing_name: name, turo_vehicle_id: num }, 'Saved: Turo emails about this car now block it', () => setEdit(false)); }}>
          <p className="small muted">Listed on Turo? Type the car&apos;s name exactly as Turo&apos;s emails show it, so the emails find this car. The plate and VIN are matched too.</p>
          <div className="cs-trip__fields">
            <div className="field"><label className="label" htmlFor={`ln-${id}`}>Name on Turo</label>
              <input className="input" id={`ln-${id}`} maxLength={120} value={name} onChange={(e) => setName(e.target.value)} placeholder="Mercedes-Benz GLC 2021" /></div>
            <div className="field"><label className="label" htmlFor={`lv-${id}`}>Turo car number (optional)</label>
              <input className="input" id={`lv-${id}`} inputMode="numeric" maxLength={12} value={num} onChange={(e) => setNum(e.target.value)} placeholder="The number at the end of its Turo page address" /></div>
          </div>
          <div className="row cs-actions">
            <button type="submit" className="btn btn--primary btn--sm" disabled={pending || (!name.trim() && !num.trim())}>Save</button>
            {link && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setEdit(false)}>Cancel</button>}
          </div>
        </form>
      ) : link && (
        <p className="small"><b>{link.listing_name ?? 'Turo car ' + link.turo_vehicle_id}</b>{link.turo_vehicle_id && link.listing_name ? ` · Turo car ${link.turo_vehicle_id}` : ''}{enabled ? '' : ' · Turo by email is off'}
          {' '}<button type="button" className="btn btn--quiet btn--sm" onClick={() => setEdit(true)}>Change</button>
          <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { if (confirm('Stop matching Turo emails to this car? Its Turo trips stay on the calendar.')) act('turo_link_remove', { vehicle: car.id }, 'Removed'); }}>Not on Turo</button></p>
      )}
      {car.turo.trips.length > 0 && (
        <ul className="cs-events small" aria-label={`Turo trips of ${car.name}`} data-testid="turo-trips">{car.turo.trips.map((t) => (
          <li key={t.id}>{at(t.starts_at)} to {at(t.ends_at)}: Turo trip {t.trip_id.startsWith('M-') ? '(added by hand)' : t.trip_id}{t.guest_first_name ? ` (${t.guest_first_name})` : ''}{t.blocked ? '' : ' (block removed by staff)'}
            {' '}<button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { if (confirm('Cancelled on Turo? This frees the car here.')) act('turo_trip_cancel', { id: t.id }, 'Trip cancelled: the car is free again'); }}>Cancelled</button></li>))}</ul>
      )}
      {(link || car.turo.trips.length > 0) && <details className="cs-more" open={add} onToggle={(e) => setAdd(e.currentTarget.open)}>
        <summary className="small">Add a Turo trip</summary>
        {add && <TripForm carId={car.id} onDone={(m) => { setAdd(false); onDone(m); }} />}
      </details>}
      {link && (car.turo.block.length > 0 || car.turo.free.length > 0) && (
        <div className="cs-block" data-testid="turo-block">
          <h4 className="cs-h">Block on Turo</h4>
          <p className="small muted">Turo cannot read our calendar. Block these dates on the car&apos;s Turo calendar, then tick Done on Turo.</p>
          <ul className="ad-list">
            {car.turo.block.map((b) => (
              <li key={b.booking_id} data-testid="turo-block-item"><span><Link prefetch={false} className="link" href={`${bookingBase}/${encodeURIComponent(b.booking_number)}`}>{b.booking_number}</Link>: block {at(b.starts_at)} to {at(b.ends_at)}
                {b.was ? <span className="small ad-late"> (dates changed: free {at(b.was.starts_at)} to {at(b.was.ends_at)} first)</span> : ''}</span>
                <button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={() => act('turo_block_done', { booking: b.booking_id }, 'Ticked')}>Done on Turo</button></li>))}
            {car.turo.free.map((b) => (
              <li key={b.booking_id} data-testid="turo-free-item"><span>{b.booking_number} ({b.why}): free {at(b.starts_at)} to {at(b.ends_at)} on Turo</span>
                <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => act('turo_unblock_done', { booking: b.booking_id }, 'Ticked')}>Freed on Turo</button></li>))}
          </ul>
        </div>
      )}
      {err && <p className="small ad-late" role="alert">{err}</p>}
    </div>
  );
}
