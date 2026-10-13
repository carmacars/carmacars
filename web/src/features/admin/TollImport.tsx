'use client';
import Link from 'next/link';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { uploadAdminDocument } from '@/server/actions/admin-portal';
import { useDoor } from './door';

// Bulk import of a toll or ticket statement (10-tolls-tickets-damages.md section 3): the file is read
// in the browser, its columns are mapped once per operator and header row (saved as a profile and
// applied again next time), and each row is validated, de-duplicated and matched by the database.
const TARGETS: Array<[string, string]> = [['plate', 'Plate'], ['transponder', 'Transponder'], ['occurred_at', 'Date and time'], ['date', 'Date only'], ['time', 'Time only'], ['amount', 'Amount ($)'],
  ['notice_number', 'Notice or transaction number'], ['external_ref', 'Other reference'], ['place', 'Place'], ['entry', 'Entry'], ['exit', 'Exit'], ['due_on', 'Due date']];
type Result = { batch_id: string; rows: number; imported: number; duplicates: number; invalid: number; rows_total_cents: number; difference_cents: number | null; matched: Record<string, number> | null; results: Array<{ row_no: number; result: string; reason?: string; ticket_id?: string }> };

export function parseCsv(text: string): string[][] {
  const out: string[][] = []; let row: string[] = []; let cell = ''; let q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (q) { if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c; continue; }
    if (c === '"') q = true; else if (c === ',') { row.push(cell); cell = ''; } else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); cell = ''; if (row.some((x) => x.trim())) out.push(row); row = []; } else cell += c;
  }
  row.push(cell); if (row.some((x) => x.trim())) out.push(row);
  return out;
}

export function TollImport() {
  const { act: adminAct, preview: adminPreview, base } = useDoor();
  const router = useRouter();
  const [operator, setOperator] = useState('407 ETR');
  const [kind, setKind] = useState('toll_invoice');
  const [statement, setStatement] = useState('');
  const [total, setTotal] = useState('');
  const [rows, setRows] = useState<string[][]>([]);
  const [map, setMap] = useState<Record<string, string>>({});
  const [profile, setProfile] = useState<string | null>(null);
  const [doc, setDoc] = useState<{ id: string; name: string } | null>(null);
  const [res, setRes] = useState<Result | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const header = rows[0] ?? [];
  const sig = header.map((h) => h.trim().toLowerCase()).join('|');

  const load = async (text: string) => {
    const r = parseCsv(text); setRows(r); setRes(null); setErr(null);
    const h = r[0] ?? [];
    const guess: Record<string, string> = {};
    h.forEach((x, i) => { const s = x.toLowerCase(); const t = s.includes('plate') ? 'plate' : s.includes('transponder') || s.includes('tag') ? 'transponder' : s.includes('amount') || s.includes('charge') || s.includes('total') ? 'amount'
      : s.includes('date') && s.includes('time') ? 'occurred_at' : s.includes('date') ? 'date' : s.includes('time') ? 'time' : s.includes('trip') || s.includes('transaction') || s.includes('notice') ? 'notice_number' : s.includes('entry') ? 'entry' : s.includes('exit') ? 'exit' : s.includes('location') || s.includes('place') ? 'place' : '';
      if (t && !Object.values(guess).includes(t)) guess[String(i)] = t; });
    const p = await adminPreview<{ id: string; mapping: Record<string, string> } | null>('toll_profile', { operator, header_signature: h.map((x) => x.trim().toLowerCase()).join('|') });
    if (p.ok && p.data) { setProfile(p.data.id); setMap(p.data.mapping); } else { setProfile(null); setMap(guess); }
  };
  const built = () => rows.slice(1).map((r, i) => {
    const v: Record<string, string> = {};
    for (const [col, t] of Object.entries(map)) if (t) v[t] = (r[Number(col)] ?? '').trim();
    const when = v.occurred_at || [v.date, v.time].filter(Boolean).join(' ');
    const d = when ? new Date(when.replace(/^(\d{4}-\d{2}-\d{2}) (\d)/, '$1T$2')) : null;
    const amt = v.amount ? Math.round(Number(v.amount.replace(/[$,\s]/g, '')) * 100) : null;
    return { row_no: i + 2, plate: v.plate || null, transponder: v.transponder || null, occurred_at: d && !Number.isNaN(d.getTime()) ? d.toISOString() : null, time_unknown: !v.occurred_at && !v.time,
      amount_cents: Number.isFinite(amt) ? amt : null, notice_number: v.notice_number || null, external_ref: v.external_ref || null, place: v.place || null, entry: v.entry || null, exit: v.exit || null, due_on: v.due_on || null };
  });
  const saveProfile = () => start(async () => { const r = await adminAct<{ id: string }>('toll_profile_save', { profile: { operator, name: operator, header_signature: sig, mapping: map } }); if (r.ok) setProfile(r.data.id); else setErr(r.message); });
  const run = () => start(async () => {
    setErr(null);
    const r = await adminAct<Result>('toll_import', { batch: { operator, kind, statement_number: statement || null, total_cents: total ? Math.round(Number(total) * 100) : null, profile_id: profile, document_id: doc?.id ?? null, rows: built(), confirm_difference: true } }, ['/admin/tolls']);
    if (r.ok) { setRes(r.data); router.refresh(); } else setErr(r.message);
  });
  return (
    <div className="stack" data-testid="toll-import">
      <section className="pt-card ad-card ad-form" aria-labelledby="ti-1"><h2 className="d4" id="ti-1">1. The statement</h2>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor="ti-op">Operator</label><input className="input" id="ti-op" value={operator} onChange={(e) => setOperator(e.target.value)} /></div>
          <div className="field ad-field"><label className="label" htmlFor="ti-k">Kind</label><select className="select" id="ti-k" value={kind} onChange={(e) => setKind(e.target.value)}><option value="toll_invoice">Toll statement</option><option value="ticket">Tickets</option><option value="camera_offence">Camera offences</option><option value="parking">Parking</option></select></div>
          <div className="field ad-field"><label className="label" htmlFor="ti-sn">Statement number</label><input className="input" id="ti-sn" value={statement} onChange={(e) => setStatement(e.target.value)} /></div>
          <div className="field ad-field"><label className="label" htmlFor="ti-t">Statement total ($, to check)</label><input className="input" id="ti-t" inputMode="decimal" value={total} onChange={(e) => setTotal(e.target.value)} /></div>
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ti-doc">The statement itself (PDF), attached to every notice so the renter can be charged</label>
            <input className="input" id="ti-doc" type="file" accept="application/pdf,image/jpeg,image/png" onChange={(e) => { const f = e.target.files?.[0]; if (!f) return; const fd = new FormData(); fd.set('file', f); fd.set('kind', 'toll_ticket_notice'); fd.set('title', `${operator} statement ${statement}`.trim());
              start(async () => { const r = await uploadAdminDocument(fd); if (r.ok) setDoc({ id: r.data.id, name: f.name }); else setErr(r.message); }); }} />
            {doc && <span className="small" role="status">Attached: {doc.name}</span>}</div>
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor="ti-f">CSV file</label><input className="input" id="ti-f" type="file" accept=".csv,text/csv" onChange={async (e) => { const f = e.target.files?.[0]; if (f) await load(await f.text()); }} /></div>
        </div>
      </section>
      {header.length > 0 && (
        <section className="pt-card ad-card ad-form" aria-labelledby="ti-2"><h2 className="d4" id="ti-2">2. Columns {profile ? <span className="ad-b ad-b--dark">saved profile applied</span> : null}</h2>
          <div className="ad-mapping">{header.map((h, i) => (
            <div key={i} className="field"><label className="label" htmlFor={`ti-c${i}`}>{h || `Column ${i + 1}`}</label>
              <select className="select" id={`ti-c${i}`} value={map[String(i)] ?? ''} onChange={(e) => setMap({ ...map, [String(i)]: e.target.value })}><option value="">Not used</option>{TARGETS.map(([a, b]) => <option key={a} value={a}>{b}</option>)}</select>
              <span className="small muted">{rows[1]?.[i]}</span></div>))}</div>
          <div className="row"><button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={saveProfile}>Save this mapping for {operator}</button>
            <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={run} data-testid="toll-import-run">{pending ? 'Importing' : `Import ${rows.length - 1} rows`}</button></div>
        </section>
      )}
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      {res && (
        <section className="pt-card ad-card" aria-labelledby="ti-3" data-testid="toll-import-result"><h2 className="d4" id="ti-3">3. Result</h2>
          <p>{res.imported} imported, {res.duplicates} duplicates, {res.invalid} not imported. Rows total {money(res.rows_total_cents, { cents: true })}{res.difference_cents ? `, ${money(res.difference_cents, { cents: true })} different from the statement total` : ''}.</p>
          {res.matched && <p className="small">Matched: {Object.entries(res.matched).map(([k, v]) => `${k.replace(/_/g, ' ')} ${v}`).join(', ')}.</p>}
          <ul className="small">{res.results.filter((r) => r.result !== 'imported').map((r) => <li key={r.row_no}>Row {r.row_no}: {r.result}{r.reason ? `, ${r.reason}` : ''}</li>)}</ul>
          <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/tolls`}>Open the work queue</Link>
        </section>
      )}
    </div>
  );
}
