'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminSaveRow } from '@/server/actions/admin-portal';
import type { Inputs } from './engine';

// Admin > Money > Company model > Assumptions: the forecast's inputs, saved in the database (finance_model_settings,
// migration 0420) so the page, the forecast and the Excel download all use them. Percentages are typed as percentages;
// a blank "from the actuals" field uses the latest complete month; the fleet insurance premium stays blank until entered.
type Kind = 'money' | 'pct' | 'int' | 'num' | 'month';
interface F { k: keyof Inputs; label: string; kind: Kind; blank?: string; hint?: string }
const GROUPS: Array<{ title: string; fields: F[] }> = [
  { title: 'Fleet and utilization', fields: [
    { k: 'carsStart', label: 'Cars at the base month', kind: 'int', blank: 'cars' }, { k: 'carsAddedPerMonth', label: 'Cars added per month', kind: 'num' },
    { k: 'addMonths', label: 'Keep adding cars for (months)', kind: 'int' }, { k: 'utilStart', label: 'Utilization at the base month', kind: 'pct', blank: 'util' },
    { k: 'utilTarget', label: 'Target utilization', kind: 'pct' }, { k: 'utilRampMonths', label: 'Months to reach the target', kind: 'int' }] },
  { title: 'Rates', fields: [
    { k: 'ratePerDay', label: 'Revenue per rented day ($)', kind: 'money', blank: 'ratePerDay' }, { k: 'rateGrowth', label: 'Rate growth per year', kind: 'pct' },
    { k: 'feePct', label: 'Fees as % of rental', kind: 'pct', blank: 'feePct' }, { k: 'companyKeepPct', label: 'Company keeps, % of rental', kind: 'pct', blank: 'companyKeepPct', hint: 'After owner and partner shares, commissions and kickbacks.' },
    { k: 'processingPct', label: 'Payment processing', kind: 'pct' }] },
  { title: 'Costs (CAD a month)', fields: [
    { k: 'insurancePremium', label: 'Fleet insurance premium, per year ($)', kind: 'money', hint: 'Blank counts as $0 until you enter it.' }, { k: 'costGrowth', label: 'Cost growth per year', kind: 'pct' },
    { k: 'staff', label: 'Staff and contractors today ($)', kind: 'money' }, { k: 'software', label: 'Software ($)', kind: 'money' }, { k: 'marketing', label: 'Marketing ($)', kind: 'money' },
    { k: 'repairs', label: 'Repairs and maintenance ($)', kind: 'money' }, { k: 'other', label: 'Other: tolls, trackers, parking, towing ($)', kind: 'money' }] },
  { title: 'Investors, tax and cash', fields: [
    { k: 'investorRate', label: 'Return on planned raises, per year', kind: 'pct', hint: 'Investors on file use their own agreements.' }, { k: 'lockupMonths', label: 'Lockup (months)', kind: 'int' },
    { k: 'taxRate', label: 'Corporate tax rate', kind: 'pct' }, { k: 'openingCash', label: 'Opening cash at the launch month ($)', kind: 'money' }, { k: 'launchMonth', label: 'Launch month', kind: 'month' }] }
];

const show = (v: unknown, kind: Kind) => (v === null || v === undefined || v === '' ? '' : kind === 'pct' ? String(+(Number(v) * 100).toFixed(3)) : String(v));
const read = (s: string, kind: Kind): number | string | null => { const t = s.trim(); if (!t) return null; if (kind === 'month') return t.slice(0, 7); const n = Number(t.replace(/[$,%\s]/g, '')); return Number.isFinite(n) ? (kind === 'pct' ? n / 100 : n) : null; };
type Row = Record<string, string>;

export function AssumptionsForm({ inputs, base, updated }: { inputs: Inputs; base: Record<string, string>; updated: string | null }) {
  const router = useRouter();
  const [busy, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [vals, setVals] = useState<Row>(() => Object.fromEntries(GROUPS.flatMap((g) => g.fields.map((f) => [f.k, show(inputs[f.k], f.kind)]))));
  const [hires, setHires] = useState<Row[]>(inputs.hires.map((h) => ({ a: h.role, b: h.start, c: String(h.monthly) })));
  const [raises, setRaises] = useState<Row[]>(inputs.raises.map((r, i) => ({ a: `Raise ${i + 1}`, b: r.month, c: String(r.amount) })));
  const [ones, setOnes] = useState<Row[]>(inputs.oneTime.map((o) => ({ a: o.label, b: o.month, c: String(o.amount) })));
  const save = () => start(async () => {
    const out: Record<string, unknown> = {};
    for (const g of GROUPS) for (const f of g.fields) { const v = read(vals[f.k] ?? '', f.kind); if (v !== null || f.blank || f.k === 'insurancePremium') out[f.k] = v; }
    out.hires = hires.filter((h) => h.b && h.c).map((h) => ({ role: h.a || 'Hire', start: h.b, monthly: Number(h.c) }));
    out.raises = raises.filter((h) => h.b && h.c).map((h) => ({ month: h.b, amount: Number(h.c) }));
    out.oneTime = ones.filter((h) => h.b && h.c).map((h) => ({ label: h.a || 'One-time cost', month: h.b, amount: Number(h.c) }));
    const r = await adminSaveRow('finance_model_inputs', out);
    setMsg(r.ok ? { ok: true, text: 'Saved. The forecast, the pro forma and the download use these now.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  const list = (title: string, rows: Row[], set: (r: Row[]) => void, labels: [string, string, string], testId: string) => (
    <fieldset data-testid={testId}>
      <legend>{title}</legend>
      <div className="im-list">
        {rows.map((r, i) => (
          <div className="im-list__row" key={i}>
            <div className="field"><label className="label" htmlFor={`${testId}-${i}-a`}>{labels[0]}</label><input className="input" id={`${testId}-${i}-a`} value={r.a ?? ''} onChange={(e) => set(rows.map((x, j) => (j === i ? { ...x, a: e.target.value } : x)))} /></div>
            <div className="field"><label className="label" htmlFor={`${testId}-${i}-b`}>{labels[1]}</label><input className="input" id={`${testId}-${i}-b`} type="month" value={r.b ?? ''} onChange={(e) => set(rows.map((x, j) => (j === i ? { ...x, b: e.target.value } : x)))} /></div>
            <div className="field"><label className="label" htmlFor={`${testId}-${i}-c`}>{labels[2]}</label><input className="input" id={`${testId}-${i}-c`} inputMode="decimal" value={r.c ?? ''} onChange={(e) => set(rows.map((x, j) => (j === i ? { ...x, c: e.target.value } : x)))} /></div>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => set(rows.filter((_, j) => j !== i))} aria-label={`Remove ${title.toLowerCase()} row ${i + 1}`}>Remove</button>
          </div>
        ))}
      </div>
      {rows.length < 6 && <p><button type="button" className="btn btn--ghost btn--sm" onClick={() => set([...rows, { a: '', b: '', c: '' }])}>Add a row</button></p>}
    </fieldset>
  );
  return (
    <form className="im-form" onSubmit={(e) => { e.preventDefault(); save(); }} data-testid="model-assumptions">
      {GROUPS.map((g) => (
        <fieldset key={g.title}>
          <legend>{g.title}</legend>
          <div className="im-fields">
            {g.fields.map((f) => (
              <div className="field" key={f.k}>
                <label className="label" htmlFor={`as-${f.k}`}>{f.label}{f.kind === 'pct' ? ' (%)' : ''}</label>
                <input className="input" id={`as-${f.k}`} type={f.kind === 'month' ? 'month' : 'text'} inputMode={f.kind === 'month' ? undefined : 'decimal'} value={vals[f.k] ?? ''}
                  placeholder={f.blank ? `From the actuals: ${base[f.blank] ?? 'none yet'}` : f.k === 'insurancePremium' ? 'Enter the annual premium' : undefined}
                  aria-describedby={f.hint || f.blank ? `as-${f.k}-h` : undefined} onChange={(e) => setVals((v) => ({ ...v, [f.k]: e.target.value }))} data-testid={`as-${f.k}`} />
                {(f.hint || f.blank) && <p className={`small ${f.k === 'insurancePremium' && !vals[f.k] ? 'im-warn' : 'muted'}`} id={`as-${f.k}-h`}>{f.hint ?? 'Blank uses the latest complete month.'}</p>}
              </div>
            ))}
          </div>
        </fieldset>
      ))}
      {list('Staff hires', hires, setHires, ['Role', 'Start month', 'Monthly CAD'], 'as-hires')}
      {list('Planned capital raises', raises, setRaises, ['Note', 'Month funded', 'Amount CAD'], 'as-raises')}
      {list('One-time costs', ones, setOnes, ['What', 'Month paid', 'Amount CAD'], 'as-one')}
      <div className="im-actions">
        <button className="btn btn--primary" type="submit" disabled={busy} data-testid="as-save">{busy ? 'Saving' : 'Save the assumptions'}</button>
        {updated && <span className="small muted">Last saved {updated}</span>}
      </div>
      {msg && <p className={msg.ok ? 'small' : 'error'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</p>}
    </form>
  );
}
