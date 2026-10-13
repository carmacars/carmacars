'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { FieldInput, convert, type Field } from './Act';
import { adminAct, uploadAdminDocument } from '@/server/actions/admin-portal';
import { opsAct } from '@/server/actions/ops';

// Single entry of a toll, ticket or fine (docs/blueprint/10-tolls-tickets-damages.md section 3) with the
// notice itself: the scan or PDF is stored first (private documents bucket, kind toll_ticket_notice), then
// the notice is logged and matched with it attached (0021's app.log_toll_ticket keeps document_id).
const FIELDS: Field[] = [
  { name: 'kind', label: 'Kind', type: 'select', required: true, value: 'ticket', options: [['toll_invoice', 'Toll'], ['ticket', 'Ticket'], ['camera_offence', 'Camera offence'], ['parking', 'Parking'], ['fine', 'Fine'], ['tow', 'Tow'], ['impound', 'Impound']] },
  { name: 'authority', label: 'Issued by', required: true }, { name: 'notice_number', label: 'Notice number' }, { name: 'plate', label: 'Plate' }, { name: 'transponder', label: 'or transponder' },
  { name: 'occurred_at', label: 'When it happened', type: 'datetime', required: true }, { name: 'time_unknown', label: 'Time not stated (date only)', type: 'bool' },
  { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'place', label: 'Place' }, { name: 'due_on', label: 'Due date', type: 'date' }, { name: 'received_on', label: 'Received', type: 'date' }, { name: 'note', label: 'Note', type: 'textarea' }
];

export function TollEntry() {
  const idp = useId().replace(/:/g, '');
  const router = useRouter();
  const [vals, setVals] = useState<Record<string, string | boolean>>(() => Object.fromEntries(FIELDS.map((f) => [f.name, f.type === 'bool' ? false : String(f.value ?? '')])));
  const [errs, setErrs] = useState<Record<string, string>>({});
  const [file, setFile] = useState<File | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const submit = () => {
    const out: Record<string, unknown> = {}; const e: Record<string, string> = {};
    for (const f of FIELDS) { const r = convert(f, vals[f.name] ?? ''); if (r.err) e[f.name] = r.err; else out[f.name] = r.v; }
    setErrs(e);
    if (Object.keys(e).length) return;
    start(async () => {
      setErr(null);
      if (file) {
        const fd = new FormData();
        fd.set('file', file); fd.set('kind', 'toll_ticket_notice'); fd.set('title', `Notice ${String(out.notice_number ?? '')}`.trim());
        const up = await uploadAdminDocument(fd);
        if (!up.ok) { setErr(up.message); return; }
        out.document_id = up.data.id;
      }
      const r = await adminAct<{ id: string }>('toll_log', { row: out }, ['/admin/tolls']);
      if (!r.ok) { setErr(r.message); return; }
      router.push(`/admin/tolls/${r.data.id}`);
    });
  };
  return (
    <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }} data-testid="toll-log-form">
      <div className="ad-fields">
        {FIELDS.map((f) => <FieldInput key={f.name} f={f} idp={idp} value={vals[f.name] ?? ''} set={(v) => setVals((s) => ({ ...s, [f.name]: v }))} err={errs[f.name]} />)}
        <div className="field ad-field ad-field--wide">
          <label className="label" htmlFor={`${idp}-file`}>The notice (PDF, JPEG or PNG, under 15 MB)</label>
          <input className="input" id={`${idp}-file`} type="file" accept="application/pdf,image/jpeg,image/png" data-testid="toll-log-file" onChange={(e) => setFile(e.target.files?.[0] ?? null)} aria-describedby={`${idp}-file-hint`} />
          <p className="hint" id={`${idp}-file-hint`}>Kept with the notice; it is the proof the renter or owner is sent.</p>
        </div>
      </div>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="toll-log-submit">{pending ? 'Saving' : 'Save and match'}</button></div>
    </form>
  );
}

/** Attach the notice to a toll or ticket logged without it. */
export function TollAttach({ tollId }: { tollId: string }) {
  const idp = useId().replace(/:/g, '');
  const router = useRouter();
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="field">
      <label className="label" htmlFor={`${idp}-f`}>Attach the notice</label>
      <input className="input" id={`${idp}-f`} type="file" accept="application/pdf,image/jpeg,image/png" disabled={pending} data-testid="toll-attach"
        onChange={(e) => { const f = e.target.files?.[0]; if (!f) return; start(async () => {
          setErr(null);
          const fd = new FormData(); fd.set('file', f); fd.set('kind', 'toll_ticket_notice'); fd.set('title', f.name);
          const up = await uploadAdminDocument(fd);
          if (!up.ok) { setErr(up.message); return; }
          const r = await opsAct('toll_document', { toll: tollId, document: up.data.id }, [`/admin/tolls/${tollId}`]);
          if (!r.ok) setErr(r.message); else router.refresh();
        }); }} />
      {err && <p className="error" role="alert">{err}</p>}
    </div>
  );
}
