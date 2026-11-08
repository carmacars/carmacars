'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import './onboarding.css';
import { vinListCreate, vinListPreview, type VinListResult, type VinRow } from '@/server/actions/onboarding';
import { parseVinList, VIN_LIST_MAX } from './vin-list';

// Add cars from a list of VINs (r34, 0824): paste them or upload a CSV or text file; Preview decodes each VIN (year, make
// and model) and checks it; the table shows what will be made and what will not, and why; Add makes every good car in
// one step. Each car then waits for the terms to be approved, like any new car. The owner portal (Cars > Add cars) and
// the owner page of staff and Admin.
const TITLE: Array<[string, string]> = [['owned_outright', 'Owned outright'], ['financed', 'Financed'], ['leased', 'Leased']];

export function VinList({ ownerId, viewer, refresh, done }: { ownerId: string; viewer: 'owner' | 'staff' | 'admin'; refresh: string[]; done?: string }) {
  const id = useId().replace(/:/g, '');
  const router = useRouter();
  const [pending, start] = useTransition();
  const [text, setText] = useState('');
  const [extra, setExtra] = useState(0);
  const [rows, setRows] = useState<VinRow[] | null>(null);
  const [made, setMade] = useState<VinListResult | null>(null);
  const [err, setErr] = useState('');
  const good = (rows ?? []).filter((r) => r.ok);
  const lenderMissing = good.some((r) => r.title_status && r.title_status !== 'owned_outright' && !(r.finance_party_name ?? '').trim());
  const preview = () => {
    const { vins, extra: x } = parseVinList(text);
    setExtra(x); setMade(null); setErr('');
    if (!vins.length) { setErr('No VIN found. Paste one VIN a line, or upload a CSV with a VIN column.'); setRows(null); return; }
    start(async () => {
      const r = await vinListPreview(ownerId, vins);
      if (r.ok) setRows(r.data.rows.map((x) => ({ ...x, title_status: x.title_status ?? 'owned_outright' }))); else { setErr(r.message); setRows(null); }
    });
  };
  const create = () => start(async () => {
    const r = await vinListCreate(ownerId, good.map((x) => ({ vin: x.vin, title_status: x.title_status, finance_party_name: x.finance_party_name })), refresh);
    if (r.ok) { setMade(r.data); setRows(r.data.rows); router.refresh(); } else setErr(r.message);
  });
  const set = (vin: string, k: 'title_status' | 'finance_party_name', v: string) => setRows((rs) => (rs ?? []).map((x) => (x.vin === vin ? { ...x, [k]: v } : x)));
  return (
    <section className="pt-card stack" aria-labelledby={`${id}-h`} data-testid="vin-list">
      <h2 className="d4" id={`${id}-h`}>Add cars from a list of VINs</h2>
      <p className="small muted">Paste the VINs (one a line, or separated by commas), or upload a CSV or text file. Up to {VIN_LIST_MAX} at a time. We read the year, make and model from each VIN; a typo, a car already with us or one listed twice is shown and not added.</p>
      <div className="field"><label className="label" htmlFor={`${id}-t`}>VINs</label>
        <textarea className="input ob-textarea" id={`${id}-t`} value={text} onChange={(e) => { setText(e.target.value); setRows(null); setMade(null); }} placeholder={'1HGCM82633A004352\n2T1BURHE0JC000000'} data-testid="vin-list-text" /></div>
      <div className="field"><label className="label" htmlFor={`${id}-f`}>Or a file (CSV or text)</label>
        <input className="input" id={`${id}-f`} type="file" accept=".csv,.txt,text/csv,text/plain" data-testid="vin-list-file"
          onChange={async (e) => { const f = e.target.files?.[0]; e.target.value = ''; if (!f) return; if (f.size > 512_000) { setErr('The file must be under 500 KB.'); return; } setText(await f.text()); setRows(null); setMade(null); }} /></div>
      <div className="row" style={{ gap: 'var(--s-2)' }}><button type="button" className="btn btn--ghost btn--sm" disabled={pending || !text.trim()} onClick={preview} data-testid="vin-list-preview">{pending && !rows ? 'Reading the VINs' : 'Preview'}</button></div>
      {extra > 0 && <p className="small" role="status">Only the first {VIN_LIST_MAX} are read; {extra} more were left for the next list.</p>}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      {rows && (
        <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="The VINs read">
          <table className="ad-table ad-table--dense ad-table--cards ob-vins" role="table" data-testid="vin-list-table">
            <thead role="rowgroup"><tr role="row"><th role="columnheader" scope="col">VIN</th><th role="columnheader" scope="col">Car</th><th role="columnheader" scope="col">It is</th><th role="columnheader" scope="col">Result</th></tr></thead>
            <tbody role="rowgroup">{rows.map((r, i) => (
              <tr key={`${r.vin}-${i}`} role="row" data-testid="vin-list-row" data-ok={r.ok ? 'yes' : 'no'}>
                <th role="rowheader" scope="row"><code>{r.vin}</code></th>
                <td role="cell" data-label="Car">{r.year ? `${r.year} ${r.make ?? ''} ${r.model ?? ''}${r.trim ? ` ${r.trim}` : ''}` : <span className="muted">Not read</span>}</td>
                <td role="cell" data-label="It is">{r.ok && !made ? <span className="stack">
                  <label className="vh" htmlFor={`${id}-s-${i}`}>Owned, financed or leased: {r.vin}</label>
                  <select className="select select--sm" id={`${id}-s-${i}`} value={r.title_status ?? 'owned_outright'} onChange={(e) => set(r.vin, 'title_status', e.target.value)}>{TITLE.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
                  {r.title_status && r.title_status !== 'owned_outright' && <><label className="vh" htmlFor={`${id}-l-${i}`}>{r.title_status === 'leased' ? 'Lease company' : 'Lender'}: {r.vin}</label>
                    <input className="input input--sm" id={`${id}-l-${i}`} placeholder={r.title_status === 'leased' ? 'Lease company' : 'Lender'} value={r.finance_party_name ?? ''} onChange={(e) => set(r.vin, 'finance_party_name', e.target.value)} /></>}
                </span> : <span className="small">{TITLE.find(([k]) => k === r.title_status)?.[1] ?? ''}</span>}</td>
                <td role="cell" data-label="Result" className={r.ok ? undefined : 'ob-bad'}>{r.ok ? (made ? 'Added' : 'Will be added') : r.why}</td>
              </tr>))}</tbody>
          </table>
        </div>)}
      {rows && !made && <div className="row" style={{ gap: 'var(--s-2)', alignItems: 'center', flexWrap: 'wrap' }}>
        <button type="button" className="btn btn--primary btn--sm" disabled={pending || good.length === 0 || lenderMissing} onClick={create} data-testid="vin-list-create">
          {pending ? 'Adding' : `Add ${good.length} car${good.length === 1 ? '' : 's'}`}</button>
        <span className="small muted">{rows.length - good.length > 0 ? `${rows.length - good.length} not added (see why above). ` : ''}{lenderMissing ? 'Name the lender or lease company of each financed or leased car.' : ''}</span></div>}
      {made && <p className="alert alert--ok" role="status" data-testid="vin-list-done"><span>{made.good} car{made.good === 1 ? '' : 's'} added{made.application_number ? ` (application ${made.application_number})` : ''}. {viewer === 'owner' ? 'We approve the terms of each next; you see every step on its page.' : 'Each waits for the Admin to approve its terms on the application.'}{done ? ` ${done}` : ''}</span></p>}
    </section>
  );
}
