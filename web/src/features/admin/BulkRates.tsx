'use client';
import { useState, useTransition } from 'react';
import { money } from '@/lib/format';
import { adminAct, adminPreview } from '@/server/actions/admin-portal';

type Row = { vehicle_id: string; fleet_number: string | null; vehicle_label: string; old_daily_cents: number | null; new_daily_cents: number | null; old_weekly_cents: number | null; new_weekly_cents: number | null; old_monthly_cents: number | null; new_monthly_cents: number | null; will_change: boolean; note: string | null };

export function BulkRates({ classes, owners }: { classes: Array<{ code: string; label: string }>; owners: Array<{ id: string; legal_name: string }> }) {
  const [f, setF] = useState({ class: '', owner_id: '', management_mode: '', percent: '', add: '', round: '1', fields: ['daily', 'weekend', 'weekly', 'monthly'] });
  const [rows, setRows] = useState<Row[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const body = () => ({ filter: Object.fromEntries(Object.entries({ class: f.class, owner_id: f.owner_id, management_mode: f.management_mode }).filter(([, v]) => v)),
    change: { percent_bps: f.percent ? Math.round(Number(f.percent) * 100) : 0, add_cents: f.add ? Math.round(Number(f.add) * 100) : 0, round_to_cents: Math.max(1, Math.round(Number(f.round || '0.01') * 100)), fields: f.fields } });
  const run = (apply: boolean) => start(async () => {
    setMsg(null);
    if (!apply) { const r = await adminPreview<Row[]>('bulk_rate_preview', body()); if (r.ok) setRows(r.data); else setMsg(r.message); return; }
    const r = await adminAct<{ changed: number }>('bulk_rate_apply', body(), ['/admin/vehicles']);
    setMsg(r.ok ? `${r.data.changed} cars have new rates from now. Existing bookings keep theirs.` : r.message); if (r.ok) setRows(null);
  });
  const sel = (k: 'class' | 'owner_id' | 'management_mode', label: string, opts: Array<[string, string]>) => (
    <div className="field ad-field"><label className="label" htmlFor={`br-${k}`}>{label}</label><select className="select" id={`br-${k}`} value={f[k]} onChange={(e) => setF({ ...f, [k]: e.target.value })}><option value="">Any</option>{opts.map(([a, b]) => <option key={a} value={a}>{b}</option>)}</select></div>);
  return (
    <div className="stack">
      <form className="pt-card ad-card ad-form" onSubmit={(e) => { e.preventDefault(); run(false); }}>
        <div className="ad-fields">
          {sel('class', 'Class', classes.map((c) => [c.code, c.label]))}{sel('owner_id', 'Owner', owners.map((o) => [o.id, o.legal_name]))}{sel('management_mode', 'Mode', [['managed', 'Managed'], ['turo_only', 'Turo-Only']])}
          <div className="field ad-field"><label className="label" htmlFor="br-p">Change by (%)</label><input className="input" id="br-p" inputMode="decimal" value={f.percent} onChange={(e) => setF({ ...f, percent: e.target.value })} placeholder="5 or -10" /></div>
          <div className="field ad-field"><label className="label" htmlFor="br-a">Or add ($)</label><input className="input" id="br-a" inputMode="decimal" value={f.add} onChange={(e) => setF({ ...f, add: e.target.value })} /></div>
          <div className="field ad-field"><label className="label" htmlFor="br-r">Round to ($)</label><input className="input" id="br-r" inputMode="decimal" value={f.round} onChange={(e) => setF({ ...f, round: e.target.value })} /></div>
        </div>
        <fieldset className="row"><legend className="label">Rates to change</legend>{['daily', 'weekend', 'weekly', 'monthly'].map((x) => <label key={x} className="check small"><input type="checkbox" checked={f.fields.includes(x)} onChange={(e) => setF({ ...f, fields: e.target.checked ? [...f.fields, x] : f.fields.filter((y) => y !== x) })} /> <span>{x}</span></label>)}</fieldset>
        <div className="row"><button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>Preview</button>{rows && <button className="btn btn--primary btn--sm" type="button" disabled={pending || !rows.some((r) => r.will_change)} onClick={() => run(true)}>Apply to {rows.filter((r) => r.will_change).length} cars</button>}</div>
        {msg && <p className="alert" role="status"><span>{msg}</span></p>}
      </form>
      {rows && (
        <div className="table-scroll ad-scroll" role="region" aria-label="Preview" tabIndex={0}><table className="ad-table ad-table--dense"><thead><tr><th scope="col">Vehicle</th><th scope="col" className="num">Daily</th><th scope="col" className="num">Weekly</th><th scope="col" className="num">Monthly</th><th scope="col">Note</th></tr></thead>
          <tbody>{rows.map((r) => <tr key={r.vehicle_id}><td>{r.fleet_number} {r.vehicle_label}{r.will_change ? '' : ' (skipped)'}</td>
            {(['daily', 'weekly', 'monthly'] as const).map((k) => <td key={k} className="num">{money(r[`old_${k}_cents`])} to <b>{money(r[`new_${k}_cents`])}</b></td>)}<td>{r.note}</td></tr>)}</tbody></table></div>
      )}
    </div>
  );
}
