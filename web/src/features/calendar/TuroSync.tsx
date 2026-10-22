'use client';
import Link from 'next/link';
import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { calendarAct, type CalendarAction } from '@/server/actions/calendar-sync';
import { torontoToUtc } from '@/features/turo/email';

// Turo by email on Calendar sync (migrations 0063, 0088). Turo has no calendar link, so:
//   in:  Turo's trip emails block the car. No setup per car: each email is matched to a car by itself (the Turo car id,
//        VIN, plate, year, make, model, trim, colour, the trip and what earlier emails taught each car); the rare email
//        it cannot tell waits with "Which car is this?" (one click, remembered for next time); a trip can be added by hand
//   out: Turo cannot read our calendar either, so each CarmaCars booking is blocked on Turo by hand and ticked "Done on Turo"
export interface TuroTrip { id: string; trip_id: string; starts_at: string; ends_at: string; guest_first_name: string | null; guest_name?: string | null; guest_phone?: string | null;
  guest_email?: string | null; source: 'email' | 'manual'; last_kind: string; blocked: boolean }
export interface TuroBlock { booking_id: string; booking_number: string; starts_at: string; ends_at: string; was?: { starts_at: string; ends_at: string } | null }
export interface TuroFree { booking_id: string; booking_number: string; starts_at: string; ends_at: string; why: string }
export interface TuroIdentity { id: string; kind: 'turo_car_id' | 'name'; value: string; source: 'auto' | 'staff'; hits: number }
export interface TuroCarData { id: string; name: string; turo: { link: { listing_name: string | null; turo_vehicle_id: string | null } | null; trips: TuroTrip[]; block: TuroBlock[]; free: TuroFree[];
  identities?: TuroIdentity[]; candidate?: boolean } }
export interface TuroGuess { vehicle_id: string; name: string; year: number | null; colour: string | null; plate_end: string | null; score: string | number | null }
export interface TuroReview { id: string; received_at: string; subject: string | null; kind: string; reason: string | null; trip_id: string | null; vehicle_id: string | null; vehicle: string | null;
  vehicle_hint: string | null; starts_at: string | null; ends_at: string | null; guest_first_name: string | null; guest_name?: string | null; excerpt: string | null;
  pick?: boolean; guesses?: TuroGuess[]; turo_car_ids?: string[] }
export interface TuroData {
  enabled: boolean; address: string; forwarders: string; admin: boolean; last_email_at: string | null; emails_7d: number;
  confirmation: { id: string; code: string; url: string | null; received_at: string } | null;
  review: TuroReview[]; log: Array<{ id: string; received_at: string; kind: string; status: string; method: string; audit: string | null; reason: string | null }>;
  guest_note?: string; candidates?: Array<{ id: string; name: string; colour: string | null; plate_end: string | null }>; learned?: number;
}

const at = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Toronto' }) : 'never');
const STATUS: Record<string, string> = { applied: 'Done', review: 'To check', ignored: 'Ignored', notice: 'Gmail', resolved: 'Checked', dismissed: 'Dismissed' };
const METHOD: Record<string, string> = { ai: ' (with the assistant)', learned: ' (by what an earlier email taught)', staff: ' (by staff)' };
const phoneWords = (p: string | null | undefined) => (p && /^\+1\d{10}$/.test(p) ? `${p.slice(2, 5)}-${p.slice(5, 8)}-${p.slice(8)}` : p ?? '');
const guestOf = (t: { guest_name?: string | null; guest_first_name: string | null; guest_phone?: string | null }) =>
  [t.guest_name ?? t.guest_first_name, phoneWords(t.guest_phone)].filter(Boolean).join(', ');
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
  const act = (a: CalendarAction, p: Record<string, unknown>, msg: string | ((d: Record<string, unknown>) => string), after?: (d: Record<string, unknown>) => void) => start(async () => {
    setErr(null);
    const r = await calendarAct(a, p);
    if (!r.ok) setErr(r.message ?? 'That did not work.'); else { const d = (r.data ?? {}) as Record<string, unknown>; after?.(d); onDone(typeof msg === 'function' ? msg(d) : msg); }
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

/** "Which car is this?": the best guesses first, one click each, then any other car. The answer applies the trip and is
 * remembered for that car (its Turo car id and Turo name), so the next email for it matches by itself. */
function WhichCar({ r, cars, onClose, onDone }: { r: TuroReview; cars: Array<{ id: string; name: string; colour: string | null; plate_end: string | null }>; onClose: () => void; onDone: (m: string, review?: { vehicle: string }) => void }) {
  const dlg = useRef<HTMLDialogElement>(null);
  const [other, setOther] = useState('');
  const { pending, err, act } = useAct((m) => onDone(m));
  useEffect(() => { const d = dlg.current; if (d && !d.open) d.showModal(); }, []);
  const guesses = r.guesses ?? [];
  const rest = cars.filter((c) => !guesses.some((g) => g.vehicle_id === c.id));
  const choose = (vehicle: string, name: string) => act('turo_review_pick', { id: r.id, vehicle },
    (d) => (d.status === 'review' ? `${name}: remembered. The trip still needs its dates: add it below.` : `${name}: trip added, and remembered for this car's next Turo emails`),
    (d) => { dlg.current?.close(); if (d.status === 'review') onDone('', { vehicle }); });
  const plate = (p: string | null) => (p ? ` · plate ends ${p.toUpperCase()}` : '');
  return (
    <dialog ref={dlg} className="ad-dialog cs-which" aria-labelledby={`wc-${r.id}`} data-testid="turo-which-car" onClose={onClose}>
      <h2 className="d4" id={`wc-${r.id}`}>Which car is this?</h2>
      <p className="small">Turo calls it <b>{r.vehicle_hint ?? 'a car'}</b>{r.trip_id ? `, trip ${r.trip_id}` : ''}{r.starts_at ? `, ${at(r.starts_at)} to ${at(r.ends_at)}` : ''}{r.guest_name ?? r.guest_first_name ? ` (${r.guest_name ?? r.guest_first_name})` : ''}.</p>
      {guesses.length > 0 && <p className="small muted">Best guesses first.</p>}
      <ul className="cs-which__list">
        {guesses.map((g, i) => (
          <li key={g.vehicle_id}><button type="button" className={`btn ${i === 0 ? 'btn--primary' : 'btn--ghost'} cs-which__car`} disabled={pending} data-testid="turo-which-guess"
            onClick={() => choose(g.vehicle_id, g.name)}><span>{g.name}</span><span className="small">{[g.colour?.toLowerCase(), g.plate_end ? `plate ends ${g.plate_end.toUpperCase()}` : null].filter(Boolean).join(' · ') || ' '}</span></button></li>))}
      </ul>
      <form className="cs-which__other" onSubmit={(e) => { e.preventDefault(); const c = cars.find((x) => x.id === other); if (c) choose(c.id, c.name); }}>
        <div className="field"><label className="label" htmlFor={`wo-${r.id}`}>{guesses.length ? 'Another car' : 'The car'}</label>
          <select className="select" id={`wo-${r.id}`} value={other} onChange={(e) => setOther(e.target.value)} data-testid="turo-which-other">
            <option value="">Choose the car</option>{rest.map((c) => <option key={c.id} value={c.id}>{c.name}{c.colour ? `, ${c.colour.toLowerCase()}` : ''}{plate(c.plate_end)}</option>)}</select></div>
        <div className="row">
          <button type="submit" className="btn btn--primary btn--sm" disabled={pending || !other}>This car</button>
          <button type="button" className="btn btn--quiet btn--sm" onClick={() => dlg.current?.close()}>Not now</button>
        </div>
      </form>
      {err && <p className="small ad-late" role="alert">{err}</p>}
    </dialog>
  );
}

/** The page's Turo card: how the emails arrive, Gmail's confirmation code, the emails to check, the last emails. */
export function TuroPanel({ turo, cars }: { turo: TuroData; cars: Array<{ id: string; name: string }> }) {
  const router = useRouter();
  const [msg, setMsg] = useState<string | null>(null);
  const done = (m: string) => { if (m) setMsg(m); router.refresh(); };
  const { pending, err, act } = useAct(done);
  const [open, setOpen] = useState<string | null>(null);
  const [which, setWhich] = useState<string | null>(null);
  const [preset, setPreset] = useState<Record<string, string>>({});
  // To do's "Choose the car" opens the pop-up of that email (?pick=)
  const urlPick = useSearchParams().get('pick');
  const [urlDone, setUrlDone] = useState(false);
  const pickCars = turo.candidates ?? cars.map((c) => ({ ...c, colour: null, plate_end: null }));
  const whichId = which ?? (!urlDone && urlPick && turo.review.some((r) => r.id === urlPick && r.pick) ? urlPick : null);
  const whichR = turo.review.find((r) => r.id === whichId);
  return (
    <section className="pt-card ad-card cs-turo" id="turo" aria-labelledby="turo-h" data-testid="turo-panel">
      <h2 className="d4" id="turo-h">Turo by email</h2>
      <p className="small">Turo has no calendar link. Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled; those
        emails reach us from rent@&apos;s Gmail (or forwarded to <b>{turo.address}</b>) and each one blocks its car here within a minute (the
        turnaround included). The car is found by itself: nothing to set up per car.
        {turo.enabled ? '' : ' Turo by email is turned off in Program settings.'}</p>
      <p className="small muted" data-testid="turo-last">{turo.last_email_at ? `Last Turo email ${at(turo.last_email_at)} · ${turo.emails_7d} in 7 days` : 'No Turo email received yet. Set up the Gmail forwarding (Guide, Calendar sync).'}
        {turo.learned ? ` · ${turo.learned} Turo names and car numbers learned` : ''}</p>
      {turo.guest_note && <p className="small muted" data-testid="turo-guest-note">{turo.guest_note}</p>}
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
              <div className="cs-feed__head"><b>{r.subject ?? 'No subject'}</b> <span className="badge badge--red">{r.pick ? 'Which car?' : 'To check'}</span> <span className="small muted">{at(r.received_at)}</span></div>
              <p className="small">{r.reason}. Read: {[r.kind, r.trip_id && `trip ${r.trip_id}`, r.vehicle ?? (r.vehicle_hint && `"${r.vehicle_hint}"`), r.starts_at && `${at(r.starts_at)} to ${at(r.ends_at)}`, r.guest_name ?? r.guest_first_name].filter(Boolean).join(', ')}</p>
              {r.excerpt && <p className="small muted cs-excerpt">{r.excerpt}</p>}
              <div className="row cs-actions">
                {r.pick && <button type="button" className="btn btn--primary btn--sm" aria-haspopup="dialog" onClick={() => setWhich(r.id)} data-testid="turo-which-open">Which car is this?</button>}
                <button type="button" className={`btn ${r.pick ? 'btn--ghost' : 'btn--primary'} btn--sm`} onClick={() => setOpen(open === r.id ? null : r.id)} aria-expanded={open === r.id}>Add as a Turo trip</button>
                <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => act('turo_review_dismiss', { id: r.id }, 'Dismissed')}>Dismiss</button>
              </div>
              {open === r.id && <TripForm key={preset[r.id] ?? 'x'} cars={cars} email={r.id} initial={{ ...r, vehicle_id: preset[r.id] ?? r.vehicle_id }} onDone={done} />}
            </li>))}</ul>
        ) : <p className="small muted">Nothing to check. Only an email the reader cannot be sure about (which car, the dates, the trip number) waits here.</p>}
      </div>
      {whichR && <WhichCar key={whichR.id} r={whichR} cars={pickCars} onClose={() => { setWhich(null); setUrlDone(true); }}
        onDone={(m, review) => { if (review) { setPreset((x) => ({ ...x, [whichR.id]: review.vehicle })); setOpen(whichR.id); } done(m); }} />}
      {turo.log.length > 0 && (
        <details className="todo__clear"><summary className="small muted">Last emails ({turo.log.length})</summary>
          <ul className="small cs-log" data-testid="turo-log">{turo.log.map((l) => (
            <li key={l.id}><span className="muted">{at(l.received_at)}</span> {STATUS[l.status] ?? l.status}{METHOD[l.method] ?? ''}: {l.audit ?? l.reason}</li>))}</ul>
          <p className="small muted">Only what was read is kept (the car, dates, trip number, the guest&apos;s name and phone when Turo shows them), never the email itself. The log is kept 90 days.</p>
        </details>)}
      {err && <p className="small ad-late" role="alert">{err}</p>}
      {msg && <p className="small" role="status" data-testid="turo-msg">{msg}</p>}
    </section>
  );
}

/** One car's Turo part: what Turo's emails call it (learned by itself), the optional override, its Turo trips with the
 * guest, a trip by hand, and our bookings to block on Turo. */
export function TuroCar({ car, enabled, bookingBase, onDone }: { car: TuroCarData; enabled: boolean; bookingBase: string; onDone: (m: string) => void }) {
  const link = car.turo.link;
  const ids = car.turo.identities ?? [];
  const [edit, setEdit] = useState(false);
  const [name, setName] = useState(link?.listing_name ?? '');
  const [num, setNum] = useState(link?.turo_vehicle_id ?? '');
  const [add, setAdd] = useState(false);
  const { pending, err, act } = useAct(onDone);
  const id = car.id.slice(0, 8);
  const onTuro = car.turo.candidate !== false || !!link;
  return (
    <div className="cs-turocar" data-testid={`turo-car-${car.id}`}>
      <h3 className="cs-h">Turo</h3>
      <p className="small muted" data-testid="turo-learned">{ids.length
        ? <>Turo&apos;s emails call it {ids.map((i, n) => <span key={i.id}>{n ? ', ' : ''}<b>{i.kind === 'turo_car_id' ? `Turo car ${i.value}` : i.value}</b>
            <button type="button" className="btn btn--quiet btn--sm" aria-label={`Forget ${i.value}`} disabled={pending}
              onClick={() => { if (confirm(`Forget "${i.value}" for this car? Turo emails are then matched without it.`)) act('turo_identity_remove', { id: i.id }, 'Forgotten'); }}>Forget</button></span>)}. Learned from its emails.</>
        : onTuro ? 'Turo emails find this car by themselves (Turo car number, plate, VIN, year, make, model, trim and colour). Nothing to set up.'
          : 'A sample car: Turo emails match it only if you type its name on Turo below.'}</p>
      {edit ? (
        <form className="cs-add" onSubmit={(e) => { e.preventDefault(); act('turo_link_save', { vehicle: car.id, listing_name: name, turo_vehicle_id: num }, 'Saved: Turo emails with this name now go to this car', () => setEdit(false)); }}>
          <p className="small muted">Rarely needed: only if Turo&apos;s emails name this car in a way the reader cannot place. Type the name exactly as Turo&apos;s emails show it.</p>
          <div className="cs-trip__fields">
            <div className="field"><label className="label" htmlFor={`ln-${id}`}>Name on Turo (optional)</label>
              <input className="input" id={`ln-${id}`} maxLength={120} value={name} onChange={(e) => setName(e.target.value)} placeholder="Mercedes-Benz GLC 2021" /></div>
            <div className="field"><label className="label" htmlFor={`lv-${id}`}>Turo car number (optional)</label>
              <input className="input" id={`lv-${id}`} inputMode="numeric" maxLength={12} value={num} onChange={(e) => setNum(e.target.value)} placeholder="The number at the end of its Turo page address" /></div>
          </div>
          <div className="row cs-actions">
            <button type="submit" className="btn btn--primary btn--sm" disabled={pending || (!name.trim() && !num.trim())}>Save</button>
            <button type="button" className="btn btn--ghost btn--sm" onClick={() => setEdit(false)}>Cancel</button>
          </div>
        </form>
      ) : link ? (
        <p className="small">Name on Turo (override): <b>{link.listing_name ?? 'Turo car ' + link.turo_vehicle_id}</b>{link.turo_vehicle_id && link.listing_name ? ` · Turo car ${link.turo_vehicle_id}` : ''}{enabled ? '' : ' · Turo by email is off'}
          {' '}<button type="button" className="btn btn--quiet btn--sm" onClick={() => setEdit(true)}>Change</button>
          <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { if (confirm('Remove the typed name? Turo emails are still matched by themselves.')) act('turo_link_remove', { vehicle: car.id }, 'Removed'); }}>Remove</button></p>
      ) : <p className="small"><button type="button" className="btn btn--quiet btn--sm" onClick={() => setEdit(true)}>Type its name on Turo (optional)</button></p>}
      {car.turo.trips.length > 0 && (
        <ul className="cs-events small" aria-label={`Turo trips of ${car.name}`} data-testid="turo-trips">{car.turo.trips.map((t) => (
          <li key={t.id}>{at(t.starts_at)} to {at(t.ends_at)}: Turo trip {t.trip_id.startsWith('M-') ? '(added by hand)' : t.trip_id}{guestOf(t) ? ` (${guestOf(t)})` : ''}{t.blocked ? '' : ' (block removed by staff)'}
            {t.guest_phone && <> <a className="link" href={`tel:${t.guest_phone}`} aria-label={`Call ${t.guest_name ?? t.guest_first_name ?? 'the guest'}`}>Call</a></>}
            {' '}<button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { if (confirm('Cancelled on Turo? This frees the car here.')) act('turo_trip_cancel', { id: t.id }, 'Trip cancelled: the car is free again'); }}>Cancelled</button></li>))}</ul>
      )}
      {onTuro && <details className="cs-more" open={add} onToggle={(e) => setAdd(e.currentTarget.open)}>
        <summary className="small">Add a Turo trip</summary>
        {add && <TripForm carId={car.id} onDone={(m) => { setAdd(false); onDone(m); }} />}
      </details>}
      {(link || ids.length > 0 || car.turo.trips.length > 0) && (car.turo.block.length > 0 || car.turo.free.length > 0) && (
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
