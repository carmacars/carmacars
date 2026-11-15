'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffResendDriverLink } from '@/server/actions/ops40';
import { CopyLink } from '@/features/portal/CopyLink';
import { fromLocalInput, toLocalInput } from './Act';
import { useDoor } from './door';
import { DateInput } from '@/components/DateInput';

// A change staff propose to a confirmed booking (migration 0040): new pickup or return, another car, or a new rental
// charge, with the reason the renter reads. "Preview" asks the database for the new price and any problem; "Send to
// the renter" saves the proposal and emails it. The booking itself moves only when the renter accepts.
type Row = { label: string; before: string; after: string };
type Preview = { ok: boolean; problems: Array<{ code: string; message: string }>; rows?: Row[]; total_difference_cents?: number; available?: boolean;
  per_day_cents?: number; booked_days?: number; pricing?: 'rates' | 'all_in_day' | 'typed_total' | 'typed_rental';
  before?: { total_cents: number; billable_days: number }; after?: { total_cents: number; billable_days: number; rental_charge_cents: number } };
type Car = { id: string; name: string; plate: string | null; owner: string };
const at = (iso: string | null) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)) : '');
const dollars = (c: number) => `${c < 0 ? '-' : ''}$${(Math.abs(c) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export function ProposeChange({ booking, number, pickupAt, returnAt, vehicleId, rentalCents, refresh }: {
  booking: string; number: string; pickupAt: string; returnAt: string; vehicleId: string; rentalCents: number; refresh: string[];
}) {
  const door = useDoor();
  const router = useRouter();
  const [pickup, setPickup] = useState(toLocalInput(pickupAt));
  const [ret, setRet] = useState(toLocalInput(returnAt));
  const [car, setCar] = useState(vehicleId);
  const [price, setPrice] = useState('');
  const [total, setTotal] = useState('');
  const [note, setNote] = useState('');
  const [cars, setCars] = useState<Car[]>([]);
  const [prev, setPrev] = useState<Preview | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  useEffect(() => { void door.preview<Car[]>('change_vehicles', { booking }).then((r) => { if (r.ok) setCars(r.data); }); }, [booking]); // eslint-disable-line react-hooks/exhaustive-deps
  const body = () => {
    const p: Record<string, unknown> = { booking };
    const pi = fromLocalInput(pickup), ri = fromLocalInput(ret);
    if (pi && pi !== new Date(pickupAt).toISOString()) p.pickup_at = pi;
    if (ri && ri !== new Date(returnAt).toISOString()) p.return_at = ri;
    if (car && car !== vehicleId) p.vehicle_id = car;
    const n = Number(price.replace(/[$,\s]/g, ''));
    const t = Number(total.replace(/[$,\s]/g, ''));
    // r48: a total typed by staff (HST included) wins: the preview solves the rental charge that lands on it
    if (total.trim() && Number.isFinite(t)) p.total_cents = Math.round(t * 100);
    else if (price.trim() && Number.isFinite(n)) p.rental_charge_cents = Math.round(n * 100);
    return p;
  };
  // what is proposed: the total typed becomes the rental charge the preview solved for it
  const proposal = () => {
    const p = body();
    if ('total_cents' in p) { delete p.total_cents; if (prev?.after) p.rental_charge_cents = prev.after.rental_charge_cents; }
    return p;
  };
  const preview = () => start(async () => { setMsg(null); const r = await door.preview<Preview>('change_preview', body()); if (r.ok) setPrev(r.data); else setMsg({ ok: false, text: r.message }); });
  const send = () => start(async () => {
    setMsg(null);
    const r = await door.act('change_propose', { ...proposal(), note }, refresh);
    if (r.ok) { setMsg({ ok: true, text: 'Sent to the renter. The booking moves when they accept.' }); setPrev(null); setNote(''); router.refresh(); } else setMsg({ ok: false, text: r.message });
  });
  return (
    <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); preview(); }} data-testid="propose-change" aria-label={`Propose a change to booking ${number}`}>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="pc-pickup">New pickup</label><DateInput className="input" id="pc-pickup" type="datetime-local" value={pickup} onChange={(e) => { setPickup(e.target.value); setPrev(null); }} /></div>
        <div className="field ad-field"><label className="label" htmlFor="pc-return">New return</label><DateInput className="input" id="pc-return" type="datetime-local" value={ret} onChange={(e) => { setRet(e.target.value); setPrev(null); }} /></div>
        <div className="field ad-field"><label className="label" htmlFor="pc-car">Car</label>
          <select className="select" id="pc-car" value={car} onChange={(e) => { setCar(e.target.value); setPrev(null); }}>
            {!cars.some((c) => c.id === vehicleId) && <option value={vehicleId}>The booking&apos;s car</option>}
            {cars.map((c) => <option key={c.id} value={c.id}>{c.name}{c.plate ? ` (${c.plate})` : ''}{c.id === vehicleId ? ', current' : ''}</option>)}
          </select></div>
        <div className="field ad-field"><label className="label" htmlFor="pc-price">New rental charge ($, before tax)</label>
          <input className="input" id="pc-price" inputMode="decimal" placeholder={(rentalCents / 100).toFixed(2)} value={price} onChange={(e) => { setPrice(e.target.value); setPrev(null); }} aria-describedby="pc-price-hint" />
          <p className="hint" id="pc-price-hint">Leave empty: a later return costs the booking&apos;s own price a day, fees and coverage included; other changes are priced at its rates.</p></div>
        <div className="field ad-field"><label className="label" htmlFor="pc-total">Or the new total ($, HST included)</label>
          <input className="input" id="pc-total" inputMode="decimal" value={total} onChange={(e) => { setTotal(e.target.value); setPrev(null); }} aria-describedby="pc-total-hint" data-testid="propose-total" />
          <p className="hint" id="pc-total-hint">Optional: what the renter pays in all after the change. The rental charge is worked out to land on it.</p></div>
        <div className="field ad-field ad-field--wide"><label className="label" htmlFor="pc-note">Reason, for the renter</label>
          <textarea className="input ad-textarea" id="pc-note" rows={3} value={note} onChange={(e) => setNote(e.target.value)} placeholder="The car you booked needs a short service. We can keep you in it one more day." /></div>
      </div>
      {prev && (
        <div className="stack" data-testid="propose-preview">
          {prev.rows && prev.rows.length > 0 && <table className="data"><thead><tr><th scope="col">Item</th><th scope="col">Now</th><th scope="col">After</th></tr></thead>
            <tbody>{prev.rows.map((r) => <tr key={r.label}><th scope="row">{r.label}</th><td>{r.before}</td><td>{r.after}</td></tr>)}</tbody></table>}
          {prev.ok && prev.per_day_cents ? <p className="small" data-testid="propose-per-day">A day of this booking: <b>{dollars(prev.per_day_cents)}</b> in all (rental, fees and coverage, HST included).
            {prev.pricing === 'all_in_day' && prev.before && prev.after ? ` ${prev.after.billable_days - prev.before.billable_days > 0 ? `${prev.after.billable_days - prev.before.billable_days} more day${prev.after.billable_days - prev.before.billable_days === 1 ? '' : 's'} at that price` : 'The added time at that price'}: ${dollars(prev.after.total_cents)} in all.`
              : prev.pricing === 'typed_total' && prev.after ? ` The total you typed: ${dollars(prev.after.total_cents)} in all.` : ''}</p> : null}
          {prev.ok ? <p className="small">Difference for the renter: <b>{dollars(prev.total_difference_cents ?? 0)}</b> (HST included). {(prev.total_difference_cents ?? 0) > 0 ? 'Charged to their card on file when they accept.' : (prev.total_difference_cents ?? 0) < 0 ? 'Refunded after they accept, with an Admin\'s approval.' : ''}</p>
            : <ul className="alert alert--error">{prev.problems.map((p) => <li key={p.code}>{p.message}</li>)}</ul>}
        </div>
      )}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <div className="row">
        <button className="btn btn--ghost btn--sm" type="submit" disabled={pending} data-testid="propose-preview-btn">{pending ? 'Working' : 'Preview the price'}</button>
        <button className="btn btn--primary btn--sm" type="button" disabled={pending || !prev?.ok || note.trim().length < 3} onClick={send} data-testid="propose-send" aria-describedby="propose-send-why">Send to the renter</button>
      </div>
      {!pending && (!prev?.ok || note.trim().length < 3) && <p className="hint" id="propose-send-why" data-testid="propose-send-why">{!prev ? 'Press Preview the price first.' : !prev.ok ? 'Fix what the preview says first.' : 'Write the reason for the renter first.'}</p>}
    </form>
  );
}

export interface DriverLinkRow { signer_id: string; name: string; email: string | null; signed_at: string | null; expires_at: string | null; expired: boolean; sent_at: string | null; sent_count: number }

/** The additional drivers' signing links on the staff booking screen: who accepted, when each link expires, and
 *  "Send a new link" (the old one stops working; the driver is emailed when we have their address). */
export function DriverLinks({ rows, refresh }: { rows: DriverLinkRow[]; refresh: string[] }) {
  const router = useRouter();
  const [out, setOut] = useState<Record<string, { url: string; text: string }>>({});
  const [pending, start] = useTransition();
  if (!rows.length) return <p className="small muted">No additional driver on this booking.</p>;
  return (
    <ul className="ad-list" data-testid="driver-links">
      {rows.map((r) => (
        <li key={r.signer_id} className="stack" style={{ gap: 'var(--s-2)' }}>
          <span><b>{r.name}</b> {r.email ? <span className="muted small">{r.email}</span> : <span className="muted small">no email on file</span>}</span>
          <span className="small">{r.signed_at ? `Accepted ${at(r.signed_at)}` : r.expired ? 'Link expired' : `Link valid until ${at(r.expires_at)}`}{r.sent_at ? `. Emailed ${r.sent_count} time${r.sent_count === 1 ? '' : 's'}, last ${at(r.sent_at)}` : ''}</span>
          {!r.signed_at && <span className="row">
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={`staff-driver-resend-${r.signer_id}`}
              onClick={() => start(async () => { const x = await staffResendDriverLink(r.signer_id, refresh); setOut((o) => ({ ...o, [r.signer_id]: x.ok ? { url: x.data.url, text: x.data.emailed ? `Emailed to ${x.data.emailed}.` : 'New link made: copy it and send it.' } : { url: '', text: x.message } })); if (x.ok) router.refresh(); })}>
              Send a new link</button>
            {out[r.signer_id]?.url && <CopyLink url={out[r.signer_id]!.url} label="Copy the new link" />}
          </span>}
          {out[r.signer_id] && <span className="small" role="status">{out[r.signer_id]!.text}</span>}
        </li>
      ))}
    </ul>
  );
}
