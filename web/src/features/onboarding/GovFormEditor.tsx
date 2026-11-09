'use client';
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { governmentFormEdit } from '@/server/actions/onboarding';
import type { GovEdit, GovField, GovVersion } from '@/server/government-forms';

// r35 (0870): one government form corrected before it is signed, as a rental agreement is. An Admin or fleet changes the
// value of one box of the official form (or one row of the data sheet), always with a reason: the form is made again as a
// new version, the earlier versions stay below with their downloads, and every change is in the audit log. Only the
// boxes' values change; the form's own text and layout never do. The owner sees the current version only.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const STATUS: Record<string, string> = { draft: 'Something is missing', ready: 'Ready to print', printed: 'Printed', signed: 'Signed in ink', filed: 'Filed at the registry' };

export function GovFormEditor({ fill, canEdit, fields, edits, refresh, base }: { fill: string; canEdit: boolean; fields: GovField[]; edits: GovEdit[]; refresh: string[]; base: '/admin' | '/staff' }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const [value, setValue] = useState('');
  const [reason, setReason] = useState('');
  const [query, setQuery] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const picked = fields.find((f) => f.name === name) ?? null;
  const shown = useMemo(() => { const q = query.trim().toLowerCase(); return q ? fields.filter((f) => `${f.label} ${f.value ?? ''}`.toLowerCase().includes(q)) : fields; }, [fields, query]);
  const pick = (f: GovField) => { setName(f.name); setValue(f.value ?? ''); setReason(''); setMsg(null); };
  const save = (restore: boolean) => start(async () => {
    if (!picked) return;
    const r = await governmentFormEdit({ fill, field: picked.name, target: picked.target, value, reason, restore }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Saved. Version ${r.data.version} of the form is made${restore ? ' with the value from the records' : ''}.` });
    setName('');
    router.push(`${base}/government-forms/${r.data.fill}`);
    router.refresh();
  });
  const active = edits.filter((e) => !e.ended_at);
  return (
    <section className="pt-card stack" aria-labelledby="gf-edit-h" data-testid="gov-form-editor">
      <h2 className="d4" id="gf-edit-h">Values on this form</h2>
      <p className="small muted">{active.length ? `${active.length} value${active.length === 1 ? '' : 's'} changed by hand on this car's form; they stay through Make again unless discarded.` : 'Every value comes from the records.'} Only the boxes are filled: the official form&apos;s own text and layout never change.</p>
      {canEdit && !open && <div className="row"><button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid="gov-form-change">Change a value</button></div>}
      {canEdit && open && (
        <div className="stack pt-sheet">
          <div className="field"><label className="label" htmlFor="gf-q">Find a box</label>
            <input className="input" id="gf-q" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Name, VIN, address" /></div>
          <div className="table-scroll ad-scroll" tabIndex={0} role="region" aria-label="Boxes of the form">
            <table className="ad-table ad-table--dense"><thead><tr><th scope="col">Box</th><th scope="col">Value</th><th scope="col"><span className="vh">Choose</span></th></tr></thead>
              <tbody>{shown.map((f) => (
                <tr key={`${f.target}:${f.name}`} data-testid="gov-form-field" data-name={f.name} aria-selected={f.name === name}>
                  <th scope="row" className="small">{f.label}{f.page ? <span className="muted">, page {f.page}</span> : null}</th>
                  <td className="small">{f.value ?? <span className="muted">empty</span>}{f.edited ? <><br /><span className="badge badge--outline">Changed by hand</span>{f.records !== undefined ? <span className="muted"> records: {f.records ?? 'empty'}</span> : null}</> : null}</td>
                  <td><button type="button" className="btn btn--ghost btn--sm" onClick={() => pick(f)} aria-label={`Change ${f.label}`} data-testid="gov-form-pick">Change</button></td>
                </tr>))}</tbody></table></div>
          {picked && (
            <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); save(false); }} aria-label={`Change ${picked.label}`}>
              <div className="field"><label className="label" htmlFor="gf-v">{picked.label}</label>
                <input className="input" id="gf-v" value={value} maxLength={picked.max_length ?? 500} onChange={(e) => setValue(e.target.value)} data-testid="gov-form-value" aria-describedby="gf-v-h" />
                <p className="hint" id="gf-v-h">{picked.max_length ? `At most ${picked.max_length} characters fit in this box. ` : ''}Empty leaves the box empty.</p></div>
              <div className="field"><label className="label" htmlFor="gf-r">Reason (kept in the audit log)</label>
                <input className="input" id="gf-r" value={reason} onChange={(e) => setReason(e.target.value)} required data-testid="gov-form-reason" /></div>
              <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
                <button type="submit" className="btn btn--primary btn--sm" disabled={pending || reason.trim().length < 3} data-testid="gov-form-save">{pending ? 'Saving' : 'Save as a new version'}</button>
                {picked.edited && <button type="button" className="btn btn--ghost btn--sm" disabled={pending || reason.trim().length < 3} onClick={() => save(true)} data-testid="gov-form-restore">Back to the records</button>}
                <button type="button" className="btn btn--ghost btn--sm" onClick={() => { setName(''); setOpen(false); }}>Close</button>
              </div>
            </form>)}
        </div>)}
      {msg && <p className={`small ${msg.ok ? '' : 'ad-err'}`} role={msg.ok ? 'status' : 'alert'} data-testid="gov-form-msg">{msg.text}</p>}
      {edits.length > 0 && (
        <details><summary className="link">Changes made by hand ({edits.length})</summary>
          <ul className="ad-list small" data-testid="gov-form-edits">{edits.map((e) => (
            <li key={e.id}><b>{e.label}</b>: {e.value ?? 'empty'}. {e.reason} ({e.by ?? 'staff'}, {when(e.at)}){e.ended_at ? <span className="muted"> Ended {when(e.ended_at)}: {e.end_reason}</span> : null}</li>))}</ul>
        </details>)}
    </section>
  );
}

export function GovFormVersions({ versions, base }: { versions: GovVersion[]; base: '/admin' | '/staff' }) {
  if (versions.length < 2) return null;
  return (
    <section className="pt-card stack" aria-labelledby="gf-ver-h" data-testid="gov-form-versions">
      <h2 className="d4" id="gf-ver-h">Versions</h2>
      <p className="small muted">Every version of this form stays downloadable. The owner sees the current one only.</p>
      <ul className="ad-list small">{versions.map((v) => (
        <li key={v.id} data-testid="gov-form-version" data-current={v.current}>
          {/* one item: .ad-list's grid would give each text and link a column of its own (the links got 0px at 375) */}
          <span>
          <Link prefetch={false} className="link" href={`${base}/government-forms/${v.id}`}>Version {v.version}</Link>{v.current ? ' (current)' : ''}: {STATUS[v.status] ?? v.status}, {when(v.generated_at)}, {v.by === 'automatic' ? 'by itself' : `by ${v.by}`}{v.edits ? `, ${v.edits} value${v.edits === 1 ? '' : 's'} changed by hand` : ''}
          {' '}<Link prefetch={false} className="link" href={`${base}/government-forms/${v.id}/sheet`}>data sheet</Link></span>
        </li>))}</ul>
    </section>
  );
}
