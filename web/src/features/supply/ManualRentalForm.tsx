'use client';
import { useEffect, useMemo, useState, useTransition } from 'react';
import Link from 'next/link';
import { createManualRental, supplyRead, type ManualRentalResult } from '@/server/actions/supply';
import { money } from '@/lib/format';
import { SourcedChoice, priceFlags, type Choice } from '@/features/sales/SourcedChoice';
import { PRICE_TAX_OPTIONS, PRICE_TAX_LABEL, type PriceTaxSplit } from '@/features/sales/priceTax';
import { AddonPicker } from '@/features/addons/AddonPicker';
import { addonsPayload, type AddonChoice, type AddonOption } from '@/features/addons/model';

// Add a rental by hand (migration 0046): Admin > Bookings > Add a rental, the same screen for every assistant function
// and for field staff (0058). The database decides what each may do (staff: the rate sheet or a price typed with its
// reason, the promo codes and ways of payment the settings allow, never over a clash, never a past rental; field staff:
// a payment link or the saved card, the renter's details typed) and refuses with the reason. Staff choose "I sourced
// this client" or "Entered for CarmaCars". The dates decide the case (0074): upcoming, already underway (recorded as on
// trip) or past (an Admin's, kept as completed); the form says which, with nothing to tick.
type Car = { id: string; name: string; plate: string | null; car_code?: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null;
  has_rates?: boolean; listing_finished?: boolean; listing_status?: string; needs_policy_confirm?: boolean; status?: string };
type Renter = { id: string; legal_name: string; email: string | null; mobile: string | null; date_of_birth: string | null; is_blocked: boolean; card: { brand: string; last4: string } | null; bookings: number };
type Line = { description: string; amount_cents: number; hst_cents: number; charge_type: string };
type Quote = { role: 'admin' | 'va' | 'field'; phase?: Phase | null; phase_note?: string; free: boolean; clashes: Array<{ kind: string; booking_number?: string; status?: string; starts_at: string; ends_at: string | null; renter?: string; reason?: string; overlaps: boolean }>;
  turnaround_minutes: number; payment_modes: string[]; may_override_price: boolean; rate_sheet_cents: number | null; billable_days: number | null;
  price_floor_daily_cents: number | null; price_max_discount_bps: number | null; choice_required: boolean; may_search_renters: boolean; may_override_clash: boolean; may_record_past: boolean; may_promo: boolean; single_limit_cents: number | null;
  card: { brand: string; last4: string } | null; vehicle: { name: string; supply_type: string; bookable: boolean; retired: boolean };
  has_rates?: boolean; listing_finished?: boolean; needs_policy_confirm?: boolean; notes?: string[]; price_typed_cents?: number | null;
  /** The price typed, split by the database (0112): plus tax or tax included. */
  price_tax?: PriceTaxSplit | null;
  quote: { lines: Line[]; total_due_at_booking_cents: number; deposit_cents: number; km_allowance_total: number; billable_days: number; rate_rule: string; problems: Array<{ message: string }>; promo: { problem?: string } | null } };

const MODE: Record<string, [string, string]> = {
  other_way: ['Paid another way', 'e-Transfer, cheque, cash or bank transfer: recorded as a payment received another way.'],
  link: ['Send a payment link', 'The renter gets an email to sign and pay online, the usual way. The rental waits for that payment.'],
  card: ['Charge the saved card when the renter signs', 'The renter\'s card on file is charged when the renter presses Accept and sign, not before. Until then the rental is awaiting signature.'],
  unpaid: ['Unpaid: invoice later', 'Confirmed now; the balance is collected later.']
};
// what each way means for a rental already underway (0074): it is on trip from the start
const LIVE_MODE: Record<string, string> = {
  link: 'The renter gets an email to sign the agreement, then pay online from their booking. The rental is on trip already.',
  card: 'The renter\'s card on file is charged when the renter signs the agreement (Accept and sign). The rental is on trip already.',
  unpaid: 'Recorded on trip now; the balance is collected later.'
};
const SOURCES: Array<[string, string]> = [['phone', 'Phone'], ['walk_in', 'Walk-in'], ['turo', 'Turo'], ['partner', 'Partner'], ['insurer', 'Insurer'], ['email', 'Email'], ['other', 'Other']];
const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const iso = (s: string | undefined) => (s ? new Date(s).toISOString() : '');
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const cents = (s: string) => (s.trim() ? Math.round(Number(s.replace(/[$,\s]/g, '')) * 100) : undefined);

export type Phase = 'upcoming' | 'in_progress' | 'past';
/** The case the dates make, as the database decides it (app.manual_rental_phase, 0074). */
export function phaseOf(pickup: string | undefined, ret: string | undefined, now = Date.now()): Phase | null {
  const a = pickup ? new Date(pickup).getTime() : NaN;
  const b = ret ? new Date(ret).getTime() : NaN;
  if (Number.isNaN(a) || Number.isNaN(b) || b <= a) return null;
  return b <= now ? 'past' : a <= now ? 'in_progress' : 'upcoming';
}
const PHASE_NOTE: Record<Phase, string> = {
  upcoming: 'This rental starts in the future: it is confirmed now and the car is handed over at pickup as usual.',
  in_progress: 'This rental is already underway: it will be recorded as on trip, picked up at the time you entered. Anything still missing (signature, licence check, coverage proof, deposit, condition report) becomes a task.',
  past: 'This rental has already ended: it will be recorded as completed, for the history and the statements.'
};

export function ManualRentalForm({ cars, base, isAdmin }: { cars: Car[]; base: '/admin' | '/va' | '/field'; isAdmin: boolean }) {
  const field = base === '/field';
  const [choice, setChoice] = useState<Choice>(isAdmin ? 'for_carmacars' : '');
  const start0 = useMemo(() => { const d = new Date(Date.now() + 86_400_000); d.setMinutes(0, 0, 0); d.setHours(10); return d; }, []);
  const [f, setF] = useState<Record<string, string>>({ vehicle_id: '', pickup_at: local(start0), return_at: local(new Date(start0.getTime() + 3 * 86_400_000)),
    pickup_method: 'collected', return_method: 'returned', booking_type: 'standard', coverage_option: '1', price_tax: 'plus', source: 'phone', mode: base === '/field' ? 'link' : 'other_way', method: 'e_transfer',
    received_on: new Date().toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }) });
  const [flags, setFlags] = useState({ do_not_email: false, new_renter: field, policy: false });
  // add-ons (0066): the car's, with what is left for the dates; priced in the check below
  const [addons, setAddons] = useState<AddonChoice[]>([]);
  const [addonOptions, setAddonOptions] = useState<AddonOption[]>([]);
  useEffect(() => {
    if (!f.vehicle_id) return;
    let live = true;
    supplyRead<AddonOption[]>('addons_for_car', { vehicle_id: f.vehicle_id, pickup_at: iso(f.pickup_at), return_at: iso(f.return_at) })
      .then((r) => { if (live && r.ok) setAddonOptions(r.data ?? []); });
    return () => { live = false; };
  }, [f.vehicle_id, f.pickup_at, f.return_at]);
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Renter[]>([]);
  const [renter, setRenter] = useState<Renter | null>(null);
  const [drivers, setDrivers] = useState<Array<{ full_name: string; date_of_birth: string; email: string }>>([]);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<ManualRentalResult | null>(null);
  const [pending, start] = useTransition();
  const set = (k: string) => (e: { target: { value: string } }) => { setF((s) => ({ ...s, [k]: e.target.value })); if (['vehicle_id', 'pickup_at', 'return_at', 'booking_type', 'promo_code', 'coverage_option', 'pickup_method', 'return_method'].includes(k)) setQuote(null); };
  const flag = (k: keyof typeof flags) => (e: { target: { checked: boolean } }) => { setFlags((s) => ({ ...s, [k]: e.target.checked })); };
  // the case the dates make, kept current while the dates are typed (the clock moves too)
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 30_000); return () => clearInterval(t); }, []);
  const phase = phaseOf(f.pickup_at, f.return_at, now);
  const past = phase === 'past';
  // the price typed, as the database split it at the last check (0112); tax included: flagged on its amount before tax
  const typed = cents(f.rental_charge ?? '');
  const split = quote?.price_tax && typed !== undefined && quote.price_tax.tax === f.price_tax
    && (f.price_tax === 'included' ? quote.price_tax.with_tax_cents : quote.price_tax.before_tax_cents) === typed ? quote.price_tax : null;
  const typedBeforeTax = f.price_tax === 'included' ? split?.before_tax_cents : typed;
  const id = (k: string) => `mr-${k}`;
  const text = (k: string, label: string, o: { type?: string; hint?: string; inputMode?: 'decimal' | 'numeric' | 'tel' | 'email'; wide?: boolean } = {}) => (
    <div className={`field ad-field${o.wide ? ' ad-field--wide' : ''}`}><label className="label" htmlFor={id(k)}>{label}</label>
      <input className="input" id={id(k)} type={o.type ?? 'text'} inputMode={o.inputMode} value={f[k] ?? ''} onChange={set(k)} data-testid={`mr-${k}`} aria-describedby={o.hint ? `${id(k)}-h` : undefined} />
      {o.hint && <p className="hint" id={`${id(k)}-h`}>{o.hint}</p>}</div>);
  const select = (k: string, label: string, options: Array<[string, string]>) => (
    <div className="field ad-field"><label className="label" htmlFor={id(k)}>{label}</label>
      <select className="select" id={id(k)} value={f[k] ?? ''} onChange={set(k)} data-testid={`mr-${k}`}>{options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>);

  const spec = () => ({ vehicle_id: f.vehicle_id, pickup_at: iso(f.pickup_at), return_at: iso(f.return_at), booking_type: f.booking_type, coverage_option: Number(f.coverage_option),
    pickup_method: f.pickup_method, return_method: f.return_method, promo_code: f.promo_code || undefined, renter_id: renter?.id, rental_charge_cents: cents(f.rental_charge ?? ''),
    price_tax: cents(f.rental_charge ?? '') !== undefined ? f.price_tax : undefined,
    addons: addonsPayload(addons),
    drivers: [{ role: 'renter', date_of_birth: renter?.date_of_birth ?? (f.date_of_birth || undefined) }, ...drivers.filter((d) => d.date_of_birth).map((d) => ({ role: 'additional', date_of_birth: d.date_of_birth }))] });
  const check = () => start(async () => {
    setErr(null);
    if (!f.vehicle_id) { setErr('Choose the car.'); return; }
    if (!f.pickup_at || !f.return_at) { setErr('Enter the pickup and the return, each with a date and a time.'); return; }
    if (!phase) { setErr('The return must be after the pickup: check both dates and times.'); return; }
    if (past && !isAdmin) { setErr('This rental has already ended. Only an Admin can record it: check the return date and time, or ask an Admin to add it.'); return; }
    const r = await supplyRead<Quote>('manual_rental_quote', spec());
    if (!r.ok) { setErr(r.message); setQuote(null); return; }
    setQuote(r.data);
    if (!r.data.payment_modes.includes(f.mode ?? '')) setF((s) => ({ ...s, mode: r.data.payment_modes[0] ?? 'other_way' }));
  });
  const search = () => start(async () => {
    const r = await supplyRead<Renter[]>('manual_rental_renters', { q });
    if (r.ok) setFound(r.data); else setErr(r.message);
  });
  const submit = () => start(async () => {
    setErr(null);
    if (!choice) { setErr('Choose "I sourced this client" or "Entered for CarmaCars".'); return; }
    if (cents(f.rental_charge ?? '') !== undefined && !(f.price_reason ?? '').trim()) { setErr('Give the reason for the price you typed.'); return; }
    if (quote && quote.has_rates === false && cents(f.rental_charge ?? '') === undefined) { setErr('This car has no rates yet: type the rental charge for the whole rental and the reason.'); return; }
    if (quote?.needs_policy_confirm && !past && !flags.policy) { setErr('This car is not on the fleet insurance policy yet: tick the confirmation that it is insured for this rental.'); return; }
    const p = { ...spec(), sales_choice: choice, pickup_place: f.pickup_place || undefined, return_place: f.return_place || undefined, source: f.source, source_note: f.source_note || undefined, note: f.note || undefined,
      do_not_email: flags.do_not_email, additional_drivers: drivers.filter((d) => d.full_name.trim()),
      renter: renter ? undefined : { full_name: f.full_name, email: f.email, mobile: f.mobile, date_of_birth: f.date_of_birth, licence_number: f.licence_number, licence_class: f.licence_class || 'G',
        licence_issuer: f.licence_issuer || 'ON', licence_expiry: f.licence_expiry || undefined, address_line1: f.address_line1 || undefined, city: f.city || undefined, postal_code: f.postal_code || undefined },
      price_reason: f.price_reason || undefined, fleet_policy_confirmed: flags.policy || undefined,
      deposit_cents: isAdmin ? cents(f.deposit ?? '') : undefined, clash_reason: isAdmin ? f.clash_reason || undefined : undefined,
      payment: { mode: f.mode, method: f.method, reference: f.reference || undefined, received_on: f.received_on, amount_cents: cents(f.amount ?? ''), note: f.payment_note || undefined } };
    const r = await createManualRental(p);
    if (!r.ok) { setErr(r.message); return; }
    setDone(r.data);
  });

  if (done) {
    return (
      <section className="pt-card stack" aria-labelledby="mr-done" data-testid="mr-done">
        <h2 className="d3" id="mr-done">Rental {done.booking_number} added</h2>
        <p>{done.status === 'confirmed' ? 'Confirmed and on the calendar.' : done.status === 'pending_payment' ? 'The renter has the email to sign and pay online; the rental is confirmed once they pay.' : done.status === 'closed' ? 'Recorded as a completed past rental. It counts on the owner\'s or partner\'s statement and the company statement.' : done.status === 'on_rent' ? 'Recorded as on trip from the pickup you entered, and on the calendar until the return. Anything still missing (signature, licence check, coverage proof, deposit, condition report) is a task under To do.' : done.status}
          {!done.blocks_calendar && done.status === 'confirmed' ? ' It was added over a clash, so it does not block the calendar: resolve the clash before the handover.' : ''}</p>
        <p className="small" data-testid="mr-done-choice">{done.sales_sourced ? 'Marked as sourced by you: your commission is counted once the rental is completed and paid in full.' : 'Entered for CarmaCars: no commission.'}
          {done.price_flags?.length ? ' The price you typed is flagged for an Admin to review.' : ''}</p>
        {done.status === 'on_rent' && done.payment_mode === 'link' && <p className="alert alert--ok" role="status" data-testid="mr-pay-online"><span>The renter has the email to sign the agreement, then pay online from their booking.</span></p>}
        {done.charge_on_sign && <p className="alert alert--ok" role="status" data-testid="mr-charge-on-sign"><span>Awaiting signature. The saved card is charged when the renter signs the rental agreement (Accept and sign), not before.</span></p>}
        {done.card && <p className={`alert ${done.card.ok ? 'alert--ok' : 'alert--warn'}`} role="status"><span>{done.card.ok ? 'The saved card was charged.' : `The saved card was not charged: ${done.card.message ?? 'declined'}. Finance has a task; send a payment link or record a payment received another way.`}</span></p>}
        <p className="small">Total {fmt(done.total_cents)}. The renter signs the rental agreement in their portal, or you record a signature on paper from the booking.</p>
        <p className="row">{field ? <Link prefetch={false} className="btn btn--primary" href="/field/sales" data-testid="mr-open">Open My sales</Link>
          : <Link prefetch={false} className="btn btn--primary" href={`${base}/bookings/${done.booking_number}`} data-testid="mr-open">Open the booking</Link>}
          <button className="btn btn--ghost" type="button" onClick={() => { setDone(null); setQuote(null); setRenter(null); setChoice(isAdmin ? 'for_carmacars' : ''); }}>Add another</button></p>
      </section>
    );
  }
  const modes = (quote?.payment_modes ?? (isAdmin ? ['other_way', 'link', 'card', 'unpaid'] : field ? ['link', 'card'] : ['other_way', 'link', 'card'])).filter((m) => !past || m === 'other_way' || m === 'unpaid');
  const car = cars.find((x) => x.id === f.vehicle_id);
  const card = renter?.card ?? quote?.card ?? null;
  return (
    <form className="ad-form stack" noValidate data-testid="manual-rental" onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <fieldset className="stack"><legend className="d4">1. The car and the dates</legend>
        <div className="ad-fields">
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor={id('vehicle_id')}>Car</label>
            <input className="input" type="search" aria-label="Find the car by its car code or plate" placeholder="Car code (CC-7F3A) or plate" data-testid="mr-car-find"
              onChange={(e) => { const k = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ''); if (k.length < 4) return;
                const hit = cars.find((c) => { const code = (c.car_code ?? '').replace(/[^A-Z0-9]/g, ''); const plate = (c.plate ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
                  return code === k || code === `CC${k}` || plate === k; });
                if (hit) set('vehicle_id')({ target: { value: hit.id } }); }} />
            <select className="select" id={id('vehicle_id')} value={f.vehicle_id} onChange={set('vehicle_id')} data-testid="mr-vehicle_id"><option value="">Choose the car</option>
              {cars.filter((c) => past || !c.retired || c.id === f.vehicle_id).map((c) => <option key={c.id} value={c.id}>{c.name}{c.car_code ? `, ${c.car_code}` : ''}{c.plate ? `, ${c.plate}` : ''} · {c.supply_type === 'company' ? 'CarmaCars-owned' : c.supply_type === 'partner' ? 'partner' : 'owner'}{c.daily_rate_cents ? ` · ${fmt(c.daily_rate_cents)} a day` : ' · no rates yet'}{c.retired ? ' · retired' : !c.bookable ? ' · closed to new bookings' : c.listing_finished === false ? ' · Listing not finished' : ''}</option>)}</select>
            {car && !car.bookable && !car.retired && phase === 'upcoming' && <p className="hint" data-testid="mr-closed-car">This car is closed to new bookings: it takes a rental already underway (pickup in the past), not an upcoming one.</p>}
            {(() => { const c = cars.find((x) => x.id === f.vehicle_id); return c && c.listing_finished === false ? <p className="hint" data-testid="mr-unlisted-tag"><span className="ad-flag">Listing not finished</span> The car stays off the public site. {c.has_rates === false ? 'It has no rates yet: you type the rental charge with the reason. ' : ''}{c.needs_policy_confirm ? (isAdmin ? 'It is not on the fleet insurance policy yet: you confirm it is insured before adding the rental.' : 'It is not on the fleet insurance policy yet: only an Admin can add its rentals.') : ''}</p> : null; })()}</div>
          {text('pickup_at', 'Pickup', { type: 'datetime-local' })}
          {text('return_at', 'Return', { type: 'datetime-local' })}
          {select('pickup_method', 'Pickup', [['collected', 'Collected from us'], ['delivered', 'Delivered']])}
          {text('pickup_place', 'Pickup place or address')}
          {select('return_method', 'Return', [['returned', 'Returned to us'], ['picked_up', 'Picked up']])}
          {text('return_place', 'Return place or address')}
        </div>
        {phase && <p className={`alert ${past && !isAdmin ? 'alert--warn' : 'alert--ok'}`} role="status" aria-live="polite" data-testid="mr-phase" data-phase={phase}>
          <span>{past && !isAdmin ? 'This rental has already ended. Only an Admin can record it: check the dates, or ask an Admin to add it.' : PHASE_NOTE[phase]}</span></p>}
      </fieldset>

      <fieldset className="stack"><legend className="d4">2. The renter</legend>
        {renter ? (
          <p data-testid="mr-renter-chosen"><b>{renter.legal_name}</b> {renter.email} {renter.mobile} {renter.card ? `· card ${renter.card.brand} ending ${renter.card.last4}` : '· no saved card'} <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setRenter(null); setQuote(null); }}>Change</button></p>
        ) : (<>
          {field ? <p className="small muted">Type the renter&apos;s details. A renter already on file is found by their email.</p>
            : <label className="check" htmlFor={id('new')}><input id={id('new')} type="checkbox" checked={flags.new_renter} onChange={flag('new_renter')} data-testid="mr-new-renter" /> <span>A new renter (not on file)</span></label>}
          {!flags.new_renter ? (
            <div className="stack">
              <div className="row"><label className="sr-only" htmlFor={id('q')}>Find a renter</label>
                <input className="input" id={id('q')} placeholder="Name, email or phone" value={q} onChange={(e) => setQ(e.target.value)} data-testid="mr-renter-q" onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); search(); } }} />
                <button className="btn btn--ghost btn--sm" type="button" onClick={search} disabled={pending || q.trim().length < 3} data-testid="mr-renter-search">Find</button></div>
              {found.length > 0 && <ul className="stack" data-testid="mr-renter-results">{found.map((r) => (
                <li key={r.id}><button className="btn btn--quiet btn--sm" type="button" disabled={r.is_blocked} onClick={() => { setRenter(r); setQuote(null); }}>{r.legal_name}</button> <span className="small">{r.email} {r.mobile} · {r.bookings} booking(s){r.is_blocked ? ' · blocked' : ''}</span></li>))}</ul>}
            </div>
          ) : (
            <div className="ad-fields">
              {text('full_name', 'Full legal name')}{text('email', 'Email', { type: 'email', inputMode: 'email' })}{text('mobile', 'Phone', { inputMode: 'tel' })}{text('date_of_birth', 'Date of birth', { type: 'date' })}
              {text('licence_number', 'Licence number')}{text('licence_class', 'Licence class', { hint: 'G unless another class' })}{text('licence_issuer', 'Licence issued by', { hint: 'ON unless another province or country' })}{text('licence_expiry', 'Licence expiry', { type: 'date' })}
              {text('address_line1', 'Home address')}{text('city', 'City')}{text('postal_code', 'Postal code')}
            </div>)}
        </>)}
        <div className="stack"><p className="small"><b>Additional drivers</b></p>
          {drivers.map((d, i) => (
            <div className="ad-fields" key={i}>
              {(['full_name', 'date_of_birth', 'email'] as const).map((k) => (
                <div className="field ad-field" key={k}><label className="label" htmlFor={`mr-d${i}-${k}`}>{k === 'full_name' ? 'Name' : k === 'date_of_birth' ? 'Date of birth' : 'Email'}</label>
                  <input className="input" id={`mr-d${i}-${k}`} type={k === 'date_of_birth' ? 'date' : k === 'email' ? 'email' : 'text'} value={d[k]} onChange={(e) => setDrivers((s) => s.map((x, j) => (j === i ? { ...x, [k]: e.target.value } : x)))} /></div>))}
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => setDrivers((s) => s.filter((_, j) => j !== i))}>Remove</button>
            </div>))}
          <p><button className="btn btn--ghost btn--sm" type="button" onClick={() => setDrivers((s) => [...s, { full_name: '', date_of_birth: '', email: '' }])}>Add a driver</button></p>
        </div>
      </fieldset>

      <fieldset className="stack"><legend className="d4">3. The rental</legend>
        <div className="ad-fields">
          {select('booking_type', 'Booking', [['standard', 'Standard'], ['non_refundable', 'Non-refundable (fixed discount)']])}
          {select('coverage_option', 'Damage coverage', [['1', 'Option 1: the renter\'s own insurance'], ['2', 'Option 2: credit card coverage'], ['3', 'Option 3: the CarmaCars Protection Plan']])}
          {select('source', 'Where it came from', SOURCES)}
          {f.source === 'other' && text('source_note', 'Say where')}
          {text('promo_code', 'Promo code')}
          {text('note', 'Note (on the booking)', { wide: true })}
        </div>
        {f.vehicle_id && addonOptions.length > 0 && (
          <div className="stack" data-testid="mr-addons-block"><p className="small"><b>Add-ons</b> <span className="muted">optional, priced with the rental</span></p>
            <AddonPicker idPrefix="mr" staff compact options={addonOptions} value={addons} onChange={(v) => { setAddons(v); setQuote(null); }} /></div>)}
        <p><button className="btn btn--ghost" type="button" onClick={check} disabled={pending} data-testid="mr-check">{pending ? 'Checking' : 'Check the calendar and the price'}</button></p>
        {quote && (
          <div className="stack" data-testid="mr-quote">
            {quote.free ? <p className="alert alert--ok" role="status" data-testid="mr-free"><span>{quote.vehicle.name} is free for these dates (with {quote.turnaround_minutes} minutes between trips).</span></p>
              : <div className="alert alert--warn" role="alert" data-testid="mr-clash"><span>Not free: {quote.clashes.map((c) => c.kind === 'booking' ? `${c.booking_number}${c.renter ? ` (${c.renter})` : ''}${c.overlaps ? '' : ', turnaround'}` : `calendar block (${c.reason})`).join('; ')}.
                {quote.may_override_clash ? ' You may still add it, with the reason.' : ' Choose other dates or another car.'}</span></div>}
            {!quote.free && quote.may_override_clash && text('clash_reason', 'Reason to add it over the clash', { wide: true })}
            {quote.notes?.length ? <div className="alert alert--warn" role="note" data-testid="mr-notes"><span>{quote.notes.join(' ')}</span></div> : null}
            {quote.needs_policy_confirm && !past && quote.role === 'admin' && <label className="check" htmlFor={id('policy')}><input id={id('policy')} type="checkbox" checked={flags.policy} onChange={flag('policy')} data-testid="mr-policy-confirm" /> <span>I checked that this car is insured for this rental</span></label>}
            {quote.has_rates === false && quote.price_typed_cents == null ? null : <table className="ad-table" data-testid="mr-price"><caption className="sr-only">Price</caption><tbody>
              {quote.quote.lines.map((l, i) => <tr key={i}><td>{l.description}</td><td className="num">{fmt(l.amount_cents)}</td></tr>)}
              <tr><td>HST</td><td className="num">{fmt(quote.quote.lines.reduce((s, l) => s + l.hst_cents, 0))}</td></tr>
              <tr><th scope="row">{quote.has_rates === false ? 'Total with the price you typed' : 'Total from the rate sheet'}</th><td className="num"><b>{fmt(quote.quote.total_due_at_booking_cents)}</b></td></tr>
              <tr><td>Deposit at pickup</td><td className="num">{fmt(quote.quote.deposit_cents)}</td></tr>
            </tbody></table>}
            <p className="small muted">{quote.quote.rate_rule}; {quote.quote.km_allowance_total} km included.{quote.quote.problems.length ? ` ${quote.quote.problems.map((p) => p.message).join(' ')}` : ''}{quote.quote.promo?.problem ? ` Promo code: ${quote.quote.promo.problem}` : ''}</p>
            {quote.may_override_price && (
              <div className="stack" data-testid="mr-custom-price">
                {quote.has_rates === false ? <p className="small">This car has no rates yet. Type the rental charge for the whole rental, plus tax or tax included, and the reason. Press Check again to see the total.</p>
                  : <p className="small">Rental charge from the rate sheet: <b>{fmt(quote.rate_sheet_cents)}</b>. To charge another price, type it with the reason. The rate-sheet price stays on the booking for an Admin to see.</p>}
                <div className="ad-fields">{text('rental_charge', quote.has_rates === false ? 'Rental charge for the whole rental ($)' : 'Rental charge typed by hand ($, empty: the rate sheet)', { inputMode: 'decimal' })}
                  {select('price_tax', 'Tax', PRICE_TAX_OPTIONS)}{text('price_reason', 'Reason for the price')}
                  {isAdmin && text('deposit', 'Deposit ($, empty: the rate sheet)', { inputMode: 'decimal' })}</div>
                {split && <p className="small" data-testid="mr-price-tax">{PRICE_TAX_LABEL[split.tax]}: {fmt(split.before_tax_cents)} before tax and {fmt(split.hst_cents)} HST, {fmt(split.with_tax_cents)} in all.</p>}
                {(() => { const fl = priceFlags(typedBeforeTax, quote.rate_sheet_cents, quote.billable_days, quote.price_floor_daily_cents, quote.price_max_discount_bps);
                  return fl.length ? <p className="alert alert--warn" role="status" data-testid="mr-price-flag"><span>This price is {fl.join(' and ')}. You can still add the rental: it is flagged for an Admin to review.</span></p> : null; })()}
              </div>)}
          </div>)}
      </fieldset>

      <fieldset className="stack"><legend className="d4">4. Payment</legend>
        {modes.map((m) => (
          <label key={m} className="check ad-choice" htmlFor={id(`mode-${m}`)}><input type="radio" id={id(`mode-${m}`)} name="mode" value={m} checked={f.mode === m} onChange={set('mode')} data-testid={`mr-mode-${m}`}
            disabled={m === 'card' && !card} /> <span><b>{MODE[m]![0]}</b>{m === 'card' ? (card ? ` (${card.brand} ending ${card.last4})` : ' (no saved card)') : ''}<br /><span className="small muted">{phase === 'in_progress' && LIVE_MODE[m] ? LIVE_MODE[m] : MODE[m]![1]}</span></span></label>))}
        {f.mode === 'other_way' && (
          <div className="ad-fields">
            {select('method', 'How it was paid', [['e_transfer', 'e-Transfer'], ['cheque', 'Cheque'], ['cash', 'Cash'], ['bank_transfer', 'Bank transfer'], ['other', 'Another way']])}
            {text('reference', 'Reference (e-Transfer, cheque or transfer number)')}{text('received_on', 'Date received', { type: 'date' })}
            {text('amount', 'Amount ($, empty: the total)', { inputMode: 'decimal', hint: quote?.role === 'va' && quote.single_limit_cents != null ? `Your single limit is ${fmt(quote.single_limit_cents)}.` : undefined })}
            {f.method === 'other' && text('payment_note', 'How it was paid')}
          </div>)}
        <label className="check" htmlFor={id('dne')}><input id={id('dne')} type="checkbox" checked={flags.do_not_email} onChange={flag('do_not_email')} data-testid="mr-do-not-email" /> <span>Do not email the renter</span></label>
      </fieldset>

      <fieldset className="stack"><legend className="d4">5. Who found this client</legend>
        <SourcedChoice id="mr" value={choice} onChange={setChoice} optional={isAdmin} />
      </fieldset>

      {err && <p className="alert alert--error" role="alert" data-testid="mr-error"><span>{err}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={pending || !quote} data-testid="mr-submit">{pending ? 'Working' : past ? 'Record the past rental' : phase === 'in_progress' ? 'Add the rental already underway' : 'Add the rental'}</button>
        {!quote && <span className="small muted">Check the calendar and the price first.</span>}</div>
    </form>
  );
}
