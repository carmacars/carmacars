'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminSaveRow } from '@/server/actions/admin-portal';

// Program settings > Staff agreement defaults by function (migration 0057): what a staff agreement generated from the
// record starts with. Assistants: pay (monthly or hourly), the rate, full or part time, days a week and hours a day for
// each function, and the values every assistant's agreement shares. Field staff: the hourly wage and pay dates. Saved
// as one value (program_settings.staff_agreement_defaults) in a new dated row; the Admin can still change any value
// before sending an agreement.
type Fn = 'cs' | 'fleet' | 'finance' | 'sales';
interface ByFn { pay_basis: string; rate: string; schedule: string; days_per_week: string; hours_per_day: string }
export interface StaffDefaultsValue {
  va?: { country?: string; currency?: string; platform?: string; pay_timing?: string; trial_days?: string; coverage?: string; by_function?: Partial<Record<Fn, Partial<ByFn>>> } & Record<string, unknown>;
  field?: { wage?: string; currency?: string; vehicle_types?: string; pay_dates?: string; licence_years?: string } & Record<string, unknown>;
}
const FNS: Array<[Fn, string]> = [['cs', 'Customer service'], ['fleet', 'Fleet'], ['finance', 'Finance'], ['sales', 'Sales']];
const COMMON: Array<[string, string, string?]> = [['currency', 'Currency', 'For example USD'], ['country', 'Country'], ['platform', 'Hiring platform (payment)'],
  ['pay_timing', 'Payment timing', 'For example every two weeks, or monthly'], ['trial_days', 'Trial Period (days)'], ['coverage', 'Days and times', 'For example Monday to Saturday, 9:00 to 19:00, or as set in the weekly roster']];
const FIELD: Array<[string, string, string?]> = [['wage', 'Hourly wage (CA$)', 'For example 18.00'], ['pay_dates', 'Pay dates', 'For example every two weeks'],
  ['vehicle_types', 'Vehicle types authorized'], ['licence_years', 'Minimum licence period (years)']];
const blank: ByFn = { pay_basis: '', rate: '', schedule: '', days_per_week: '', hours_per_day: '' };
const num = (v: string) => /^\d+(\.\d+)?$/.test(v.trim());

export function StaffDefaults({ value }: { value: StaffDefaultsValue }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [va, setVa] = useState<Record<string, string>>(() => Object.fromEntries(COMMON.map(([k]) => [k, String(value.va?.[k] ?? '')])));
  const [by, setBy] = useState<Record<Fn, ByFn>>(() => Object.fromEntries(FNS.map(([f]) => [f, { ...blank, ...(value.va?.by_function?.[f] ?? {}) }])) as Record<Fn, ByFn>);
  const [field, setField] = useState<Record<string, string>>(() => Object.fromEntries(FIELD.map(([k]) => [k, String(value.field?.[k] ?? '')])));
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const setFn = (f: Fn, k: keyof ByFn, v: string) => setBy((b) => ({ ...b, [f]: { ...b[f], [k]: v } }));

  const save = (e: React.FormEvent) => {
    e.preventDefault();
    for (const [f, l] of FNS) {
      const x = by[f];
      for (const k of ['rate', 'days_per_week', 'hours_per_day'] as const) if (x[k] && !num(x[k])) { setMsg({ ok: false, text: `${l}: write the ${k === 'rate' ? 'rate' : k === 'days_per_week' ? 'days a week' : 'hours a day'} as a number.` }); return; }
      if (x.days_per_week && Number(x.days_per_week) > 7) { setMsg({ ok: false, text: `${l}: at most 7 days a week.` }); return; }
      if (x.hours_per_day && Number(x.hours_per_day) > 24) { setMsg({ ok: false, text: `${l}: at most 24 hours a day.` }); return; }
    }
    if (field.wage && !num(field.wage)) { setMsg({ ok: false, text: 'Field staff: write the hourly wage as a number.' }); return; }
    const next = {
      ...value,
      va: { ...(value.va ?? {}), ...Object.fromEntries(Object.entries(va).map(([k, v]) => [k, v.trim()])), by_function: Object.fromEntries(FNS.map(([f]) => [f, Object.fromEntries(Object.entries(by[f]).map(([k, v]) => [k, v.trim()]))])) },
      field: { ...(value.field ?? {}), ...Object.fromEntries(Object.entries(field).map(([k, v]) => [k, v.trim()])), currency: 'CAD' }
    };
    start(async () => {
      const r = await adminSaveRow('program_settings', { staff_agreement_defaults: next }, 'current');
      setMsg(r.ok ? { ok: true, text: 'Saved. New agreements start from these values.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    });
  };

  return (
    <form className="stack" noValidate onSubmit={save} data-testid="staff-defaults-form">
      <p className="small muted">What a staff agreement starts with when you press Send the agreement to sign. You can still change any value before sending. An empty value is asked for at that time. The agreements allow no commission.</p>
      <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Assistants by function">
        <table className="ad-table ad-table--dense">
          <caption className="vh">Assistants by function</caption>
          <thead><tr><th scope="col">Function</th><th scope="col">Pay</th><th scope="col">Rate</th><th scope="col">Schedule</th><th scope="col">Days a week</th><th scope="col">Hours a day</th></tr></thead>
          <tbody>{FNS.map(([f, l]) => (
            <tr key={f} data-testid={`staff-defaults-${f}`}>
              <th scope="row">{l}</th>
              <td><label className="vh" htmlFor={`${idp}-${f}-pay`}>{l}: pay</label>
                <select className="select" id={`${idp}-${f}-pay`} value={by[f].pay_basis} onChange={(e) => setFn(f, 'pay_basis', e.target.value)} data-testid={`sd-${f}-pay_basis`}>
                  <option value="">Not set</option><option value="monthly">A month</option><option value="hourly">An hour</option></select></td>
              <td><label className="vh" htmlFor={`${idp}-${f}-rate`}>{l}: rate</label>
                <input className="input" id={`${idp}-${f}-rate`} inputMode="decimal" value={by[f].rate} onChange={(e) => setFn(f, 'rate', e.target.value)} data-testid={`sd-${f}-rate`} size={8} /></td>
              <td><label className="vh" htmlFor={`${idp}-${f}-sch`}>{l}: schedule</label>
                <select className="select" id={`${idp}-${f}-sch`} value={by[f].schedule} onChange={(e) => setFn(f, 'schedule', e.target.value)} data-testid={`sd-${f}-schedule`}>
                  <option value="">Not set</option><option value="full_time">Full time</option><option value="part_time">Part time</option></select></td>
              <td><label className="vh" htmlFor={`${idp}-${f}-days`}>{l}: days a week</label>
                <input className="input" id={`${idp}-${f}-days`} inputMode="numeric" value={by[f].days_per_week} onChange={(e) => setFn(f, 'days_per_week', e.target.value)} data-testid={`sd-${f}-days_per_week`} size={3} /></td>
              <td><label className="vh" htmlFor={`${idp}-${f}-hours`}>{l}: hours a day</label>
                <input className="input" id={`${idp}-${f}-hours`} inputMode="decimal" value={by[f].hours_per_day} onChange={(e) => setFn(f, 'hours_per_day', e.target.value)} data-testid={`sd-${f}-hours_per_day`} size={3} /></td>
            </tr>))}
          </tbody>
        </table>
      </div>
      <h3 className="d4">Every assistant</h3>
      <div className="ad-fields">{COMMON.map(([k, l, hint]) => (
        <div key={k} className="field ad-field"><label className="label" htmlFor={`${idp}-va-${k}`}>{l}</label>
          <input className="input" id={`${idp}-va-${k}`} value={va[k] ?? ''} onChange={(e) => setVa((v) => ({ ...v, [k]: e.target.value }))} aria-describedby={hint ? `${idp}-va-${k}-h` : undefined} data-testid={`sd-va-${k}`} />
          {hint && <p className="hint" id={`${idp}-va-${k}-h`}>{hint}</p>}</div>))}</div>
      <h3 className="d4">Field staff</h3>
      <div className="ad-fields">{FIELD.map(([k, l, hint]) => (
        <div key={k} className="field ad-field"><label className="label" htmlFor={`${idp}-field-${k}`}>{l}</label>
          <input className="input" id={`${idp}-field-${k}`} value={field[k] ?? ''} onChange={(e) => setField((v) => ({ ...v, [k]: e.target.value }))} aria-describedby={hint ? `${idp}-field-${k}-h` : undefined} data-testid={`sd-field-${k}`} />
          {hint && <p className="hint" id={`${idp}-field-${k}-h`}>{hint}</p>}</div>))}</div>
      {msg && <p className={msg.ok ? 'small' : 'alert alert--error'} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="staff-defaults-save">{pending ? 'Saving' : 'Save the defaults'}</button></div>
    </form>
  );
}
