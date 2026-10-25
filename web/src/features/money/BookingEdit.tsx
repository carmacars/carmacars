'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo } from '@/server/actions/offers';
import { cents } from '@/features/offers/model';
import type { Fees } from './BookingFees';
import { BalanceActions } from './BalanceActions';
import { Info } from '@/features/forms/Info';
import { lineHelp } from '@/features/offers/help';
import { AddressInput } from '@/features/forms/AddressInput';

// Edit a booking that is confirmed, on trip, returned or (an Admin) closed, directly (migration 0132): the pickup and the
// return (extend or shorten), the car, the rental charge, each fee, the kilometres, the deposit and the note, in one form.
// The totals are repriced, the edit is recorded with who, when and why, and the renter is told what changed or not
// (a silent correction). The database decides who may and refuses with the reason.
export interface EditForm {
  booking_number: string; status: string; refusal: string | null; admin: boolean;
  now: { pickup_at: string; return_at: string; vehicle_id: string; vehicle: string; billable_days: number; rental_charge_cents: number; km_allowance_per_day: number; deposit_cents: number; notes: string | null; total_cents: number; custom_price: boolean; pickup_place?: string | null; return_place?: string | null };
  cars: Array<{ id: string; name: string; plate: string | null; car_code: string | null }>;
  edits: Array<{ at: string; by: string | null; status: string; reason: string | null; told_renter: boolean; changes: Array<{ label: string; field: string }>; total_before_cents: number; total_after_cents: number }>;
}
const pad = (n: number) => String(n).padStart(2, '0');
const local = (iso: string) => { const d = new Date(iso); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });

export function BookingEdit({ x, fees }: { x: EditForm; fees: Fees | null }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ pickup_at: local(x.now.pickup_at), return_at: local(x.now.return_at), vehicle_id: x.now.vehicle_id, rental: '', km: String(x.now.km_allowance_per_day), deposit: '', notes: x.now.notes ?? '', reason: '', pickup_place: x.now.pickup_place ?? '', return_place: x.now.return_place ?? '' });
  const [lines, setLines] = useState<Record<string, string>>({});
  const [tell, setTell] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  if (x.refusal && !x.edits.length) return null;
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));
  const save = () => run(async () => {
    setMsg(null);
    const changes: Record<string, unknown> = {};
    if (f.pickup_at !== local(x.now.pickup_at)) changes.pickup_at = new Date(f.pickup_at).toISOString();
    if (f.return_at !== local(x.now.return_at)) changes.return_at = new Date(f.return_at).toISOString();
    if (f.vehicle_id !== x.now.vehicle_id) changes.vehicle_id = f.vehicle_id;
    if (cents(f.rental) !== null) changes.rental_charge_cents = cents(f.rental);
    if (f.km !== String(x.now.km_allowance_per_day) && f.km.trim()) changes.km_allowance_per_day = Number(f.km);
    if (x.admin && cents(f.deposit) !== null) changes.deposit_cents = cents(f.deposit);
    if (f.notes !== (x.now.notes ?? '')) changes.notes = f.notes;
    if (f.pickup_place !== (x.now.pickup_place ?? '')) changes.pickup_place = f.pickup_place;
    if (f.return_place !== (x.now.return_place ?? '')) changes.return_place = f.return_place;
    const fl = Object.fromEntries(Object.entries(lines).filter(([, v]) => cents(v) !== null).map(([k, v]) => [k, cents(v)]));
    if (!Object.keys(changes).length && !Object.keys(fl).length) { setMsg({ ok: false, text: 'Nothing changed yet: change a date, the car, a price or a fee.' }); return; }
    const r = await offersDo<{ changed: boolean; note: string; total_before_cents: number; total_cents: number; open_cents: number }>('booking_staff_edit',
      { booking: x.booking_number, changes, lines: fl, reason: f.reason.trim() || undefined, tell_renter: tell });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Saved. Total ${fmt(r.data.total_before_cents)} to ${fmt(r.data.total_cents)}.${r.data.open_cents > 0 ? ` ${fmt(r.data.open_cents)} to collect (Money tab).` : ''}${tell ? ' The renter has an email with what changed.' : ''}` });
    setOpen(false); setLines({}); setF((s) => ({ ...s, rental: '', deposit: '', reason: '' })); router.refresh();
  });
  const text = (k: keyof typeof f, label: string, o: { type?: string; hint?: string; inputMode?: 'decimal' | 'numeric' } = {}) => (
    <div className="field ad-field"><label className="label" htmlFor={`be-${k}`}>{label}</label>
      <input className="input" id={`be-${k}`} type={o.type ?? 'text'} inputMode={o.inputMode} value={f[k]} onChange={set(k)} data-testid={`be-${k}`} />{o.hint && <p className="hint">{o.hint}</p>}</div>);
  return (
    <section className="pt-card ad-card stack" aria-labelledby="be-h" data-testid="booking-edit">
      <div className="pt-card__head"><h2 className="d4" id="be-h">Edit the booking</h2>
        {!x.refusal && !open && <button className="btn btn--primary btn--sm" type="button" onClick={() => setOpen(true)} data-testid="be-open">Edit</button>}</div>
      {x.refusal ? <p className="small muted">{x.refusal}.</p> : !open && <p className="small muted">Dates (extend or shorten), car, rental charge, fees, kilometres{x.admin ? ', deposit' : ''} and the note, even on trip{x.admin ? ' or closed' : ''}. Each edit is recorded.</p>}
      {open && <div className="stack">
        <div className="ad-fields">
          {text('pickup_at', 'Pickup', { type: 'datetime-local' })}
          {text('return_at', 'Return', { type: 'datetime-local', hint: `Now ${x.now.billable_days} days. A new length is repriced at this booking's rates${x.now.custom_price ? ' (the price typed by hand, the same a day)' : ''}.` })}
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="be-vehicle_id">Car</label>
            <select className="select" id="be-vehicle_id" value={f.vehicle_id} onChange={set('vehicle_id')} data-testid="be-vehicle_id">
              {x.cars.map((c) => <option key={c.id} value={c.id}>{c.name}{c.car_code ? `, ${c.car_code}` : ''}{c.plate ? `, ${c.plate}` : ''}</option>)}</select>
            {f.vehicle_id !== x.now.vehicle_id && x.status === 'on_rent' && <p className="hint">A swap during the trip: the car it leaves goes to Out of service until Fleet checks it.</p>}</div>
          {(['pickup_place', 'return_place'] as const).map((k) => <div className="field ad-field" key={k}><label className="label" htmlFor={`be-${k}`}>{k === 'pickup_place' ? 'Pickup place or address' : 'Return place or address'}</label>
            <AddressInput id={`be-${k}`} name={k} value={{ label: f[k], placeId: '' }} onChange={(v) => setF((s) => ({ ...s, [k]: v.label }))} testId={`be-${k}`} /></div>)}
          {text('rental', `Rental charge for the whole trip, before fees and tax ($, now ${fmt(x.now.rental_charge_cents)}; empty: keep, or reprice for new dates)`, { inputMode: 'decimal' })}
          {text('km', 'Kilometres a day', { inputMode: 'numeric' })}
          {x.admin && text('deposit', `Deposit ($, now ${fmt(x.now.deposit_cents)})`, { inputMode: 'decimal' })}
          {(fees?.lines ?? []).map((l) => (
            <div key={l.key} className="field ad-field"><label className="label" htmlFor={`be-fee-${l.key}`}>{l.label} ($ for the trip, now {fmt(l.amount_cents)})<Info text={lineHelp(l.key.startsWith('addon:') ? 'addon' : l.key)} /></label>
              <input className="input" id={`be-fee-${l.key}`} inputMode="decimal" value={lines[l.key] ?? ''} onChange={(e) => setLines((s) => ({ ...s, [l.key]: e.target.value }))} data-testid={`be-fee-${l.key}`} /></div>))}
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="be-notes">Note on the booking</label>
            <textarea className="input ad-textarea" id="be-notes" value={f.notes} onChange={set('notes')} data-testid="be-notes" /></div>
          {text('reason', 'Why (kept with the edit, optional)')}
        </div>
        <label className="check" htmlFor="be-tell"><input id="be-tell" type="checkbox" checked={tell} onChange={(e) => setTell(e.target.checked)} data-testid="be-tell" /> <span>Email the renter what changed (leave it off for a silent correction)</span></label>
        <p className="small muted">To have the renter accept and sign before the change applies, use Propose a change on the Changes tab instead.</p>
        <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={save} data-testid="be-save">{pending ? 'Saving' : 'Save the changes'}</button>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button></div>
      </div>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="be-msg"><span>{msg.text}</span></p>}
      {msg?.ok && fees?.parts && <BalanceActions booking={x.booking_number} open={fees.parts.balance} rental={fees.parts.rental} fees={fees.parts.fees} card={fees.card} reach={fees.renter_reach} why={f.reason || 'the changes to your booking'} />}
      {x.edits.length > 0 && <details data-testid="be-edits"><summary className="link small">Edits ({x.edits.length})</summary>
        <ul className="stack small">{x.edits.map((e, i) => <li key={i}>{when(e.at)}{e.by ? `, ${e.by}` : ''}: {e.changes.map((c) => c.label).join(', ')}; total {fmt(e.total_before_cents)} to {fmt(e.total_after_cents)}{e.reason ? ` (${e.reason})` : ''}{e.told_renter ? ', renter told' : ', not sent to the renter'}</li>)}</ul></details>}
    </section>
  );
}
