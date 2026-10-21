'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { supplyDo } from '@/server/actions/supply';
import { RateFields } from '@/features/rates/RateFields';
import { ratePayload, ratesEmpty, type RateCheck } from '@/features/rates/rates';
import { ColourSwatches, VinEntry, effectiveCar, emptyVin, vinPayload, vinProblem, type VinValue } from '@/features/vin/VinEntry';

// Admin > Vehicles > Add a car (migration 0046; VIN first since 0079): the VIN, decoded at once into one summary line
// (year, make, model, trim, body, seats, doors, fuel, drive, gearbox, engine), the colour in one tap, the class
// inferred and the rates pre-filled from it; then who supplies it (a program owner, CarmaCars, or a partner rental
// company). The title, description and features are written by the listing pipeline right after the car is added.
// The duplicate check is the database's: one VIN once in the fleet, a plate on one active car, and the similarity
// check of 0040 (a likely twin waits for staff before it is published).
type Opt = { id: string; name: string; note?: string };
const SUPPLY: Array<[string, string, string]> = [
  ['program_owner', 'A program owner\'s car', 'The owner pays the fees and gets the owner statement. The car starts its onboarding (terms, agreements, registry).'],
  ['company', 'CarmaCars-owned (company fleet)', 'No owner: every dollar of revenue is CarmaCars\', and CarmaCars pays its costs. It appears in the company statement as company fleet.'],
  ['partner', 'A partner rental company\'s car', 'Brokered: CarmaCars keeps its commission, the partner gets the rest on a monthly partner statement.']
];

export function AddCarForm({ owners, partners, defaultCommission }: { owners: Opt[]; partners: Opt[]; defaultCommission: number }) {
  const router = useRouter();
  const [supply, setSupply] = useState('company');
  const [v, setV] = useState<Record<string, string>>({ title_status: 'owned_outright', management_mode: 'managed' });
  const [car, setCar] = useState<VinValue>(emptyVin());
  const [more, setMore] = useState(false);
  const [rates, setRates] = useState<Record<string, string>>({ km_mode: 'default' });
  const [chk, setChk] = useState<RateCheck | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const set = (k: string) => (e: { target: { value: string } }) => setV((s) => ({ ...s, [k]: e.target.value }));
  const input = (k: string, label: string, o: { type?: string; hint?: string; required?: boolean; inputMode?: 'decimal' | 'numeric' } = {}) => (
    <div className="field ad-field"><label className="label" htmlFor={`ac-${k}`}>{label}{o.required ? '' : ' (optional)'}</label>
      <input className="input" id={`ac-${k}`} type={o.type ?? 'text'} inputMode={o.inputMode} value={v[k] ?? ''} onChange={set(k)} data-testid={`add-car-${k}`} aria-describedby={o.hint ? `ac-${k}-h` : undefined} />
      {o.hint && <p className="hint" id={`ac-${k}-h`}>{o.hint}</p>}</div>
  );
  const submit = () => start(async () => {
    setErr(null);
    const problem = vinProblem(car);
    if (problem) { setErr(problem); return; }
    if (car.facts?.taken && car.mode === 'vin') { setErr(`This VIN is already in the fleet: ${car.facts.taken.name}.`); return; }
    if (!ratesEmpty(rates) && chk && !chk.ok) { setErr(`Check the rates: ${chk.messages.join(' ')}`); return; }
    const p: Record<string, unknown> = {
      supply_type: supply, ...vinPayload(car), plate: car.mode === 'plate' ? car.plate.toUpperCase().replace(/\s/g, '') : v.plate || undefined,
      odometer_km: v.odometer_km ? Number(v.odometer_km) : undefined, home_location: v.home_location || undefined,
      rates: ratesEmpty(rates) ? undefined : ratePayload(rates)
    };
    if (supply === 'program_owner') Object.assign(p, { owner_id: v.owner_id, title_status: v.title_status, management_mode: v.management_mode, finance_party_name: v.finance_party_name });
    if (supply === 'partner') Object.assign(p, { partner_id: v.partner_id, commission_bps: v.commission ? Math.round(Number(v.commission) * 100) : undefined });
    const r = await supplyDo<{ vehicle_id: string }>('vehicle_add', p, ['/admin/vehicles']);
    if (!r.ok) { setErr(r.message); return; }
    router.push(`/admin/vehicles/${r.data.vehicle_id}?added=1`);
  });
  const ec = effectiveCar(car);
  return (
    <form className="ad-form stack" noValidate data-testid="add-car" onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <fieldset className="stack"><legend className="d4">The car</legend>
        <VinEntry value={car} onChange={setCar} prefix="add-car" carHref={(id) => `/admin/vehicles/${id}`} />
        <ColourSwatches value={car.colour} onChange={(c) => setCar((x) => ({ ...x, colour: c }))} prefix="add-car" legend="Colour (optional)"
          hint="Not in the VIN. Leave it empty and it is read from the cover photo once there is one." />
        {car.mode === 'vin' && input('plate', 'Plate', { hint: 'Optional when the VIN is given.' })}
        {!more ? <button type="button" className="link vin-switch" onClick={() => setMore(true)} data-testid="add-car-more">Odometer and home area (optional)</button> : (
          <div className="ad-fields">{input('odometer_km', 'Odometer (km)', { inputMode: 'numeric' })}{input('home_location', 'Home area')}</div>)}
      </fieldset>
      <fieldset className="stack"><legend className="d4">Who supplies the car</legend>
        {SUPPLY.map(([k, l, note]) => (
          <label key={k} className="check ad-choice" htmlFor={`ac-s-${k}`}>
            <input type="radio" id={`ac-s-${k}`} name="supply" value={k} checked={supply === k} onChange={() => setSupply(k)} data-testid={`add-car-supply-${k}`} />
            <span><b>{l}</b><br /><span className="small muted">{note}</span></span>
          </label>))}
      </fieldset>
      {supply === 'program_owner' && (
        <p className="alert alert--info" data-testid="add-car-program-owner"><span>Setting up a car for an owner with their terms, documents and first invoice, or for a new owner? Use <Link prefetch={false} className="link" href="/admin/owners/add-car" data-testid="add-car-owner-flow">Add a car for an owner</Link>: the owner gets one email to review and sign.</span></p>)}
      {supply === 'program_owner' && (
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="ac-owner_id">Owner</label>
            <select className="select" id="ac-owner_id" value={v.owner_id ?? ''} onChange={set('owner_id')} data-testid="add-car-owner"><option value="">Choose the owner</option>{owners.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}</select></div>
          <div className="field ad-field"><label className="label" htmlFor="ac-title">Title</label>
            <select className="select" id="ac-title" value={v.title_status} onChange={set('title_status')}><option value="owned_outright">Owned outright</option><option value="financed">Financed</option><option value="leased">Leased</option></select></div>
          {v.title_status !== 'owned_outright' && input('finance_party_name', 'Lender or lease company', { required: true })}
          <div className="field ad-field"><label className="label" htmlFor="ac-mode">How it is managed</label>
            <select className="select" id="ac-mode" value={v.management_mode} onChange={set('management_mode')}><option value="managed">Managed</option><option value="self_managed">Self-Managed</option><option value="turo_only">Turo-Only</option></select></div>
        </div>)}
      {supply === 'partner' && (
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="ac-partner_id">Partner rental company</label>
            <select className="select" id="ac-partner_id" value={v.partner_id ?? ''} onChange={set('partner_id')} data-testid="add-car-partner"><option value="">Choose the partner</option>{partners.map((o) => <option key={o.id} value={o.id}>{o.name}{o.note ? ` (${o.note})` : ''}</option>)}</select>
            {!partners.length && <p className="hint">No partner yet: add one in <Link prefetch={false} className="link" href="/admin/partners">Partners</Link> first.</p>}</div>
          {input('commission', 'Commission for this car (%)', { inputMode: 'decimal', hint: `Empty: the partner's commission (the default is ${defaultCommission / 100}%).` })}
        </div>)}
      <fieldset className="stack"><legend className="d4">Rates and kilometres</legend>
        <p className="small muted">The daily rate starts from similar cars, else the class. Keep it to post the car in one pass, change it, or empty it and set the rates on the car&apos;s Rates tab. The kilometres start from the defaults.</p>
        <RateFields v={rates} set={(k, x) => setRates((s) => ({ ...s, [k]: x }))} context={{ class: car.class, make: ec.make ?? '', model: ec.model ?? '' }} prefix="add-car" optional onCheck={setChk} />
      </fieldset>
      {err && <p className="alert alert--error" role="alert" data-testid="add-car-error"><span>{err}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={pending} data-testid="add-car-submit">{pending ? 'Adding' : 'Add the car'}</button></div>
    </form>
  );
}
