'use client';
import { useEffect, useRef, useState } from 'react';
import { FdIcon } from '@/features/field/icons';
import { FieldReport } from '@/features/field/FieldReport';
import { SPEND_KINDS, toCents } from './model';
import { Msg, PhotoPick, sendWork, useRun } from './Steps';

// The one Add button of the field portal (r35 part X): money spent, a service record, photos of a car, a problem with a car.
// Money spent goes to Finance to approve and pay back (a To do while the receipt is missing); a service record goes on the
// car, makes its expense line and tells Fleet and Finance (0930).
type Car = { id: string; name: string };
type Booking = { id: string; number: string; vehicle: string };
const ITEMS: Array<[string, string]> = [['oil_filter', 'Oil and filter'], ['tire_rotation', 'Tire rotation'], ['brake_inspection', 'Brake inspection'], ['brake_pads_rotors', 'Brake pads and rotors'],
  ['tires', 'New tires'], ['battery', 'Battery'], ['wipers', 'Wiper blades'], ['alignment', 'Wheel alignment'], ['fluids', 'Fluids']];
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());

export function AddButton({ cars, bookings, reportCars, preps = {}, startOpen = null }: { cars: Car[]; bookings: Booking[]; reportCars: Array<{ id: string; name: string; job: string }>;
  /** the onboarding prep of a car today: its money is linked to it */ preps?: Record<string, string>;
  startOpen?: 'menu' | 'money' | 'service' | 'photos' | 'problem' | null }) {
  const [what, setWhat] = useState<null | 'menu' | 'money' | 'service' | 'photos' | 'problem'>(startOpen);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => { if (what) panel.current?.querySelector<HTMLElement>('button, input, select')?.focus(); }, [what]);
  useEffect(() => {
    if (!what) return;
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') setWhat(null); };
    window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k);
  }, [what]);
  const title = { menu: 'Add', money: 'Money spent', service: 'Service record', photos: 'Photos of a car', problem: 'A problem with a car' };
  return (
    <>
      <button type="button" className="fp-fab" onClick={() => setWhat('menu')} aria-haspopup="dialog" data-testid="add-button"><FdIcon name="plus" />Add</button>
      {what && <div className="fp-sheet" role="presentation" onClick={(e) => { if (e.target === e.currentTarget) setWhat(null); }}>
        <div className="fp-sheet__panel" role="dialog" aria-modal="true" aria-labelledby="fp-add-h" ref={panel} data-testid="add-sheet">
          <div className="fp-sheet__head">
            {what !== 'menu' ? <button type="button" className="fp-sheet__x" onClick={() => setWhat('menu')} aria-label="Back"><FdIcon name="back" /></button> : <span />}
            <h2 id="fp-add-h">{title[what]}</h2>
            <button type="button" className="fp-sheet__x" onClick={() => setWhat(null)} aria-label="Close"><FdIcon name="cross" /></button>
          </div>
          {what === 'menu' && <ul className="fp-choices">
            <li><button type="button" onClick={() => setWhat('money')} data-testid="add-money"><FdIcon name="receipt" /><b>Money spent</b><span>Gas, a wash, parts, parking. With the receipt photo.</span></button></li>
            <li><button type="button" onClick={() => setWhat('service')} data-testid="add-service"><FdIcon name="wrench" /><b>Service record</b><span>A service or repair done on a car, with the invoice.</span></button></li>
            <li><button type="button" onClick={() => setWhat('photos')} data-testid="add-photos"><FdIcon name="camera" /><b>Photos of a car</b><span>Anything Fleet should see, with a note.</span></button></li>
            <li><button type="button" onClick={() => setWhat('problem')} data-testid="add-problem"><FdIcon name="alert" /><b>A problem with a car</b><span>Damage, a warning light, a ticket, lost property.</span></button></li>
          </ul>}
          {what === 'money' && <MoneyForm cars={cars} bookings={bookings} preps={preps} done={() => setWhat(null)} />}
          {what === 'service' && <ServiceForm cars={cars} preps={preps} done={() => setWhat(null)} />}
          {what === 'photos' && <PhotoForm cars={cars} done={() => setWhat(null)} />}
          {what === 'problem' && (reportCars.length ? <FieldReport vehicles={reportCars} /> : <p className="small">A problem is reported on a car of one of your jobs. You have none in the last days: call the office.</p>)}
        </div>
      </div>}
    </>
  );
}

function CarSelect({ id, cars, value, set, optional }: { id: string; cars: Car[]; value: string; set: (v: string) => void; optional?: boolean }) {
  return <div className="field"><label className="label" htmlFor={id}>Car{optional ? ' (if it was for a car)' : ''}</label>
    <select id={id} className="select" value={value} onChange={(e) => set(e.target.value)}>
      {optional && <option value="">No car</option>}{cars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></div>;
}

function MoneyForm({ cars, bookings, preps, done }: { cars: Car[]; bookings: Booking[]; preps: Record<string, string>; done: () => void }) {
  const [kind, setKind] = useState('gas');
  const [desc, setDesc] = useState('');
  const [amount, setAmount] = useState('');
  const [hst, setHst] = useState('');
  const [car, setCar] = useState(cars[0]?.id ?? '');
  const [booking, setBooking] = useState('');
  const [paid, setPaid] = useState<'own' | 'company'>('own');
  const [file, setFile] = useState<File | null>(null);
  const { pending, msg, run, setMsg } = useRun();
  const carBookings = bookings.filter((b) => b.vehicle === car);
  const save = () => {
    const a = toCents(amount);
    if (!a) { setMsg({ ok: false, text: 'Enter the amount, for example 45.00.' }); return; }
    run(() => sendWork('spend_add', { kind, description: desc || SPEND_KINDS.find((k) => k[0] === kind)?.[1], amount_cents: a, hst_cents: toCents(hst) ?? 0, vehicle: car || null,
      booking: booking || null, paid_with: paid, spent_on: today(), prep: preps[car] ?? null }, file), file ? 'Sent to Finance.' : 'Sent to Finance. Add the receipt photo soon: it is on your To do.', () => setTimeout(done, 900));
  };
  return (
    <div className="fp-form" data-testid="money-form">
      <div className="field"><label className="label" htmlFor="m-kind">What for</label>
        <select id="m-kind" className="select" value={kind} onChange={(e) => setKind(e.target.value)}>{SPEND_KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
      <div className="field"><label className="label" htmlFor="m-desc">What you bought</label>
        <input id="m-desc" className="input" value={desc} maxLength={300} onChange={(e) => setDesc(e.target.value)} placeholder="For example: a full tank" /></div>
      <div className="fp-row2">
        <div className="field"><label className="label" htmlFor="m-amt">Amount before tax ($)</label><input id="m-amt" className="input fd-num" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="m-hst">HST ($, if any)</label><input id="m-hst" className="input fd-num" inputMode="decimal" value={hst} onChange={(e) => setHst(e.target.value)} /></div>
      </div>
      <CarSelect id="m-car" cars={cars} value={car} set={(v) => { setCar(v); setBooking(''); }} optional />
      {carBookings.length > 0 && <div className="field"><label className="label" htmlFor="m-bk">Booking (if it was for a rental)</label>
        <select id="m-bk" className="select" value={booking} onChange={(e) => setBooking(e.target.value)}><option value="">No booking</option>{carBookings.map((b) => <option key={b.id} value={b.id}>{b.number}</option>)}</select></div>}
      <div className="fp-seg" role="group" aria-label="Paid with">
        <button type="button" aria-pressed={paid === 'own'} onClick={() => setPaid('own')}>My own money</button>
        <button type="button" aria-pressed={paid === 'company'} onClick={() => setPaid('company')}>Company card</button>
      </div>
      <PhotoPick file={file} set={setFile} label="Photo of the receipt" pdf testId="money-receipt" />
      <button type="button" className="btn btn--primary fd-wide" disabled={pending} onClick={save} data-testid="money-save">{pending ? 'Sending' : 'Send to Finance'}</button>
      <Msg m={msg} />
    </div>
  );
}

function ServiceForm({ cars, preps, done }: { cars: Car[]; preps: Record<string, string>; done: () => void }) {
  const [car, setCar] = useState(cars[0]?.id ?? '');
  const [items, setItems] = useState<string[]>([]);
  const [what, setWhat] = useState('');
  const [shop, setShop] = useState('');
  const [km, setKm] = useState('');
  const [cost, setCost] = useState('');
  const [hst, setHst] = useState('');
  const [paid, setPaid] = useState<'own' | 'company'>('company');
  const [file, setFile] = useState<File | null>(null);
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-form" data-testid="service-form">
      <CarSelect id="s-car" cars={cars} value={car} set={setCar} />
      <fieldset className="stack"><legend className="label">What was done (tick what applies; any other repair: say it below)</legend>
        {ITEMS.map(([v, l]) => <label key={v} className={`fp-tick${items.includes(v) ? ' is-on' : ''}`}><input type="checkbox" checked={items.includes(v)} onChange={(e) => setItems(e.target.checked ? [...items, v] : items.filter((x) => x !== v))} />{l}</label>)}</fieldset>
      <div className="field"><label className="label" htmlFor="s-what">In your words</label><input id="s-what" className="input" value={what} maxLength={300} onChange={(e) => setWhat(e.target.value)} placeholder="For example: oil change, front pads" /></div>
      <div className="field"><label className="label" htmlFor="s-shop">Where</label><input id="s-shop" className="input" value={shop} maxLength={200} onChange={(e) => setShop(e.target.value)} placeholder="The shop's name and street" /></div>
      <div className="field"><label className="label" htmlFor="s-km">Odometer (km)</label><input id="s-km" className="input fd-num" inputMode="numeric" value={km} onChange={(e) => setKm(e.target.value.replace(/\D/g, ''))} /></div>
      <div className="fp-row2">
        <div className="field"><label className="label" htmlFor="s-cost">Cost before tax ($)</label><input id="s-cost" className="input fd-num" inputMode="decimal" value={cost} onChange={(e) => setCost(e.target.value)} /></div>
        <div className="field"><label className="label" htmlFor="s-hst">HST ($)</label><input id="s-hst" className="input fd-num" inputMode="decimal" value={hst} onChange={(e) => setHst(e.target.value)} /></div>
      </div>
      <div className="fp-seg" role="group" aria-label="Paid with">
        <button type="button" aria-pressed={paid === 'company'} onClick={() => setPaid('company')}>Company paid</button>
        <button type="button" aria-pressed={paid === 'own'} onClick={() => setPaid('own')}>My own money</button>
      </div>
      <PhotoPick file={file} set={setFile} label="Photo of the invoice" pdf testId="service-invoice" />
      <button type="button" className="btn btn--primary fd-wide" disabled={pending || !car} data-testid="service-save"
        onClick={() => run(() => sendWork('service_add', { vehicle: car, items, what: what || ITEMS.filter(([v]) => items.includes(v)).map(([, l]) => l).join(', '), shop, odometer_km: km ? Number(km) : null,
          cost_cents: toCents(cost) ?? 0, hst_cents: toCents(hst) ?? 0, paid_with: paid, prep: preps[car] ?? null }, file), 'Recorded on the car. Fleet and Finance are told.', () => setTimeout(done, 900))}>{pending ? 'Saving' : 'Record the service'}</button>
      <Msg m={msg} />
    </div>
  );
}

function PhotoForm({ cars, done }: { cars: Car[]; done: () => void }) {
  const [car, setCar] = useState(cars[0]?.id ?? '');
  const [note, setNote] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const { pending, msg, run } = useRun();
  return (
    <div className="fp-form">
      <CarSelect id="p-car" cars={cars} value={car} set={setCar} />
      <PhotoPick file={file} set={setFile} />
      <div className="field"><label className="label" htmlFor="p-note">Note</label><input id="p-note" className="input" value={note} maxLength={200} onChange={(e) => setNote(e.target.value)} placeholder="What it shows" /></div>
      <button type="button" className="btn btn--primary fd-wide" disabled={pending || !file || !car} onClick={() => run(() => sendWork('car_photo', { vehicle: car, note }, file), 'Saved on the car.', () => setTimeout(done, 900))}>{pending ? 'Saving' : 'Save the photo'}</button>
      <Msg m={msg} />
    </div>
  );
}
