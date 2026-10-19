'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { supplyDo } from '@/server/actions/supply';
import { RateFields } from '@/features/rates/RateFields';
import { ratePayload, ratesEmpty, type RateCheck } from '@/features/rates/rates';

// Admin > Vehicles > Add a car (migration 0046): who supplies it first (a program owner, CarmaCars, or a partner
// rental company), then the car. The duplicate check is the database's: one VIN once in the fleet, a plate on one
// active car, and the similarity check of 0040 (a likely twin waits for staff before it is published).
type Opt = { id: string; name: string; note?: string };
const SUPPLY: Array<[string, string, string]> = [
  ['program_owner', 'A program owner\'s car', 'The owner pays the fees and gets the owner statement. The car starts its onboarding (terms, agreements, registry).'],
  ['company', 'CarmaCars-owned (company fleet)', 'No owner: every dollar of revenue is CarmaCars\', and CarmaCars pays its costs. It appears in the company statement as company fleet.'],
  ['partner', 'A partner rental company\'s car', 'Brokered: CarmaCars keeps its commission, the partner gets the rest on a monthly partner statement.']
];

export function AddCarForm({ owners, partners, defaultCommission }: { owners: Opt[]; partners: Opt[]; defaultCommission: number }) {
  const router = useRouter();
  const [supply, setSupply] = useState('company');
  const [v, setV] = useState<Record<string, string>>({ title_status: 'owned_outright', management_mode: 'managed', fuel: 'gasoline', class: 'standard' });
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
    if (!ratesEmpty(rates) && chk && !chk.ok) { setErr(`Check the rates: ${chk.messages.join(' ')}`); return; }
    const p: Record<string, unknown> = {
      supply_type: supply, vin: v.vin, plate: v.plate, year: v.year ? Number(v.year) : undefined, make: v.make, model: v.model, trim: v.trim, colour: v.colour,
      odometer_km: v.odometer_km ? Number(v.odometer_km) : undefined, fuel: v.fuel, class: v.class, home_location: v.home_location,
      rates: ratesEmpty(rates) ? undefined : ratePayload(rates)
    };
    if (supply === 'program_owner') Object.assign(p, { owner_id: v.owner_id, title_status: v.title_status, management_mode: v.management_mode, finance_party_name: v.finance_party_name });
    if (supply === 'partner') Object.assign(p, { partner_id: v.partner_id, commission_bps: v.commission ? Math.round(Number(v.commission) * 100) : undefined });
    const r = await supplyDo<{ vehicle_id: string }>('vehicle_add', p, ['/admin/vehicles']);
    if (!r.ok) { setErr(r.message); return; }
    router.push(`/admin/vehicles/${r.data.vehicle_id}?added=1`);
  });
  return (
    <form className="ad-form stack" noValidate data-testid="add-car" onSubmit={(e) => { e.preventDefault(); submit(); }}>
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
      <fieldset className="stack"><legend className="d4">The car</legend>
        <div className="ad-fields">
          {input('vin', 'VIN (17 characters)', { required: true })}
          {input('plate', 'Plate')}
          {input('year', 'Year', { inputMode: 'numeric', hint: 'Year, make and model are taken from the VIN decode when one is on file.' })}
          {input('make', 'Make')}
          {input('model', 'Model')}
          {input('trim', 'Trim')}
          {input('colour', 'Colour')}
          {input('odometer_km', 'Odometer (km)', { inputMode: 'numeric' })}
          <div className="field ad-field"><label className="label" htmlFor="ac-class">Deposit class</label>
            <select className="select" id="ac-class" value={v.class} onChange={set('class')}>{['economy', 'standard', 'premium', 'suv', 'luxury', 'exotic'].map((c) => <option key={c} value={c}>{c[0]!.toUpperCase() + c.slice(1)}</option>)}</select></div>
          {input('home_location', 'Home area')}
        </div>
      </fieldset>
      <fieldset className="stack"><legend className="d4">Rates and kilometres</legend>
        <p className="small muted">Type the rates now to post the car in one pass, or leave them empty and set them on the car&apos;s Rates tab. The kilometres start from the defaults.</p>
        <RateFields v={rates} set={(k, x) => setRates((s) => ({ ...s, [k]: x }))} context={{ class: v.class, make: v.make, model: v.model }} prefix="add-car" optional onCheck={setChk} />
      </fieldset>
      {err && <p className="alert alert--error" role="alert" data-testid="add-car-error"><span>{err}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={pending} data-testid="add-car-submit">{pending ? 'Adding' : 'Add the car'}</button></div>
    </form>
  );
}
