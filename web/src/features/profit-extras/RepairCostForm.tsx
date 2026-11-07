'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo } from '@/server/actions/staff-tools';
import { DateInput } from '@/components/DateInput';
import { toStandardImage } from '@/features/uploads/standard-image';
import { PAID_BY, type Repair } from './model';

const UPKEEP: Array<[string, string]> = [['engine', 'Engine'], ['transmission', 'Transmission'], ['shocks', 'Shocks and struts'], ['rustproofing', 'Rustproofing'],
  ['refurbishment', 'Refurbishment not part of a claim'], ['tires', 'Tires'], ['brakes', 'Brakes'], ['oil_change', 'Oil changes'], ['ball_joints', 'Ball joints']];

// A repair cost on a car (migration 0581): the date, the shop (a partner) or another vendor, what was done, the amount
// and tax, who paid, the claim, and a receipt (a photo made smaller on the device, or a PDF; private storage).
// Admin, Finance and Fleet; from the car or from a claim.
export function RepairCostForm({ vehicleId, claimId, partners, claims, cars, edit, refresh }: {
  vehicleId?: string | null; claimId?: string | null; partners: Array<{ id: string; name: string }>; claims?: Array<{ id: string; claim_number: string }> | null;
  cars?: Array<{ id: string; name: string }> | null; edit?: Repair & { vendor_partner_id?: string | null }; refresh: string[];
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ vehicle_id: edit?.vehicle_id ?? vehicleId ?? '', claim_id: edit?.claim_id ?? claimId ?? '', spent_on: edit?.on_date ?? '', vendor_partner_id: '',
    vendor_name: edit?.vendor ?? '', description: edit?.description ?? '', amount: edit ? (edit.cents / 100).toFixed(2) : '', tax: edit ? (edit.tax_cents / 100).toFixed(2) : '', paid_by: edit?.paid_by ?? 'company', cost_type: '' });
  const [file, setFile] = useState<File | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (k: keyof typeof f) => (v: string) => setF((s) => ({ ...s, [k]: v }));
  const cents = (s: string) => Math.round(Number(s.replace(/[$,\s]/g, '') || '0') * 100);
  const save = () => start(async () => {
    setMsg(null);
    if (!f.vehicle_id && !f.claim_id) { setMsg({ ok: false, text: 'Choose the car.' }); return; }
    if (!Number.isFinite(cents(f.amount)) || !f.amount) { setMsg({ ok: false, text: 'Enter the amount.' }); return; }
    let receipt_path: string | null = null;
    if (file) {
      const fd = new FormData();
      fd.append('vehicle', f.vehicle_id);
      fd.append('file', file.type === 'application/pdf' ? file : await toStandardImage(file), file.type === 'application/pdf' ? 'receipt.pdf' : 'receipt.jpg');
      const r = await fetch('/api/staff/profit-extras', { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({}))) as { ok?: boolean; path?: string; message?: string };
      if (!j.ok || !j.path) { setMsg({ ok: false, text: j.message ?? 'The receipt could not be uploaded.' }); return; }
      receipt_path = j.path;
    }
    const r = await staffDo('repair_cost_save', { id: edit?.id, vehicle_id: f.vehicle_id || null, claim_id: f.claim_id || null, spent_on: f.spent_on || null,
      vendor_partner_id: f.vendor_partner_id || null, vendor_name: f.vendor_partner_id ? null : f.vendor_name, description: f.description, amount_cents: cents(f.amount), tax_cents: cents(f.tax),
      paid_by: f.paid_by, receipt_path, ...(f.cost_type ? { cost_type: f.cost_type } : {}) }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setOpen(false); setFile(null); setMsg({ ok: true, text: 'Saved.' });
    router.refresh();
  });
  const id = edit?.id ?? 'new';
  if (!open) return (<span className="row">
    <button className={`btn ${edit ? 'btn--ghost' : 'btn--primary'} btn--sm`} type="button" onClick={() => setOpen(true)} data-testid={`rc-open-${id}`}>{edit ? 'Change' : 'Add a repair cost'}</button>
    {msg?.ok && <span className="small" role="status">{msg.text}</span>}</span>);
  return (
    <form className="stack ad-form" data-testid={`rc-form-${id}`} onSubmit={(e) => { e.preventDefault(); save(); }}>
      <div className="ad-fields">
        {cars && cars.length > 0 && !vehicleId && <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-car`}>Car</label>
          <select className="select" id={`rc-${id}-car`} value={f.vehicle_id} onChange={(e) => set('vehicle_id')(e.target.value)} required={!f.claim_id}>
            <option value="">Choose</option>{cars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></div>}
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-d`}>Date (empty: today)</label><DateInput className="input" id={`rc-${id}-d`} type="date" value={f.spent_on} onChange={(e) => set('spent_on')(e.target.value)} /></div>
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-p`}>Shop (a partner)</label>
          <select className="select" id={`rc-${id}-p`} value={f.vendor_partner_id} onChange={(e) => set('vendor_partner_id')(e.target.value)}>
            <option value="">Another vendor (type it)</option>{partners.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></div>
        {!f.vendor_partner_id && <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-v`}>Vendor</label><input className="input" id={`rc-${id}-v`} value={f.vendor_name} onChange={(e) => set('vendor_name')(e.target.value)} data-testid="rc-vendor" /></div>}
        <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`rc-${id}-w`}>What was done</label><input className="input" id={`rc-${id}-w`} required value={f.description} onChange={(e) => set('description')(e.target.value)} data-testid="rc-description" /></div>
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-a`}>Amount before tax ($)</label><input className="input" id={`rc-${id}-a`} inputMode="decimal" required value={f.amount} onChange={(e) => set('amount')(e.target.value)} data-testid="rc-amount" /></div>
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-t`}>Tax ($)</label><input className="input" id={`rc-${id}-t`} inputMode="decimal" value={f.tax} onChange={(e) => set('tax')(e.target.value)} /></div>
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-b`}>Paid by</label>
          <select className="select" id={`rc-${id}-b`} value={f.paid_by} onChange={(e) => set('paid_by')(e.target.value)} data-testid="rc-paid-by">{PAID_BY.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        {/* 0640: on a fleet lease car, the cost type bills the party its Upkeep Table names (the supplier's: off its lease payments) */}
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-k`}>Upkeep type (fleet lease cars)</label>
          <select className="select" id={`rc-${id}-k`} value={f.cost_type} onChange={(e) => set('cost_type')(e.target.value)} data-testid="rc-cost-type">
            <option value="">Not an upkeep cost</option>{UPKEEP.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        {claims && claims.length > 0 && !claimId && <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-c`}>Claim</label>
          <select className="select" id={`rc-${id}-c`} value={f.claim_id} onChange={(e) => set('claim_id')(e.target.value)}><option value="">None</option>{claims.map((c) => <option key={c.id} value={c.id}>{c.claim_number}</option>)}</select></div>}
        <div className="field ad-field"><label className="label" htmlFor={`rc-${id}-r`}>Receipt (photo or PDF){edit?.receipt ? ': a new one replaces it' : ''}</label>
          <input className="input" id={`rc-${id}-r`} type="file" accept="image/*,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></div>
      </div>
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="rc-save">{pending ? 'Saving' : 'Save the repair cost'}</button>
        <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button>
      </div>
    </form>
  );
}
