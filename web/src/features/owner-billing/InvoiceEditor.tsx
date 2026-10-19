'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import { issueInvoice, saveDraft, type LineInput } from '@/server/actions/owner-billing';
import { dollars, hstOf, toCents } from './shared';

// A draft owner invoice, line by line (migration 0067): description, quantity, unit amount to the cent, HST on or off
// per line, a note per line; the title, due date and notes of the invoice. Saved as a draft, or saved and issued.
// An issued invoice never comes here: it is voided and a corrected one is made.
export interface DraftLine { kind?: string; description: string; quantity: number | string; unit_amount_cents: number; hst: boolean; note?: string | null }
interface Row { kind?: string; description: string; quantity: string; unit: string; hst: boolean; note: string }
const toRow = (l: DraftLine): Row => ({ kind: l.kind, description: l.description, quantity: String(l.quantity ?? 1), unit: dollars(l.unit_amount_cents), hst: l.hst, note: l.note ?? '' });
const KEEP = new Set(['prepaid_credit', 'late_fee']);

export function InvoiceEditor({ draft, cars, applicationId, hstBps, paths = [], kinds = true, stay = false }: {
  draft?: { id: string; vehicle_id: string; kind: string; title: string | null; notes: string | null; due_on: string | null; lines: DraftLine[] };
  cars: Array<{ id: string; name: string }>; applicationId?: string; hstBps: number; paths?: string[]; kinds?: boolean; stay?: boolean;
}) {
  const router = useRouter();
  const a = useAct<{ id: string; invoice_number: string; status: string; total_cents: number }>();
  const uid = `ie-${useId().replace(/[^\w-]/g, '')}`;
  const [vehicle, setVehicle] = useState(draft?.vehicle_id ?? (cars.length === 1 ? cars[0]!.id : ''));
  const [kind, setKind] = useState(draft?.kind ?? 'custom');
  const [title, setTitle] = useState(draft?.title ?? '');
  const [due, setDue] = useState(draft?.due_on ?? '');
  const [notes, setNotes] = useState(draft?.notes ?? '');
  const [rows, setRows] = useState<Row[]>((draft?.lines ?? []).filter((l) => !KEEP.has(l.kind ?? '')).map(toRow).concat(draft ? [] : [{ description: '', quantity: '1', unit: '', hst: true, note: '' }]));
  const [msg, setMsg] = useState<string | null>(null);
  const set = (i: number, k: keyof Row, v: string | boolean) => setRows(rows.map((r, j) => (j === i ? { ...r, [k]: v } : r)));
  const amount = (r: Row) => { const u = toCents(r.unit); const q = Number(r.quantity); return Number.isFinite(u) && Number.isFinite(q) ? Math.round(q * u) : 0; };
  const sub = rows.reduce((s, r) => s + amount(r), 0);
  const hst = rows.reduce((s, r) => s + (r.hst ? hstOf(amount(r), hstBps) : 0), 0);
  const kept = (draft?.lines ?? []).filter((l) => KEEP.has(l.kind ?? ''));
  const save = (issue: boolean) => {
    setMsg(null);
    const lines: LineInput[] = rows.map((r) => ({ kind: r.kind, description: r.description, quantity: r.quantity, unit_amount_cents: toCents(r.unit), hst: r.hst, note: r.note || undefined }));
    a.run(() => saveDraft({ id: draft?.id, vehicle_id: draft ? undefined : vehicle, kind: draft ? undefined : kind, title, notes, due_on: due || undefined, application_id: applicationId, lines }, paths), async (r) => {
      if (!r.ok) return;
      if (issue) {
        const x = await issueInvoice(r.data.id, paths);
        if (!x.ok) { setMsg(x.message); return; }
      }
      if (!stay) router.push(`/admin/invoices/${r.data.invoice_number}${issue ? '?issued=1' : '?saved=1'}`);
      else router.refresh();
    });
  };
  const err = (k: string) => a.err(k);
  return (
    <form className="stack ob-editor" noValidate aria-label={draft ? 'Edit the draft invoice' : 'New invoice'} data-testid="invoice-editor" onSubmit={(e) => { e.preventDefault(); save(false); }}>
      {!draft && (
        <div className="field-row">
          <div className={`field${err('vehicle_id') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-car`}>Car</label>
            <select className="select" id={`${uid}-car`} value={vehicle} onChange={(e) => setVehicle(e.target.value)} data-testid="invoice-car" aria-describedby={`${uid}-car-err`}>
              <option value="">Choose the car</option>{cars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
            <p className="error" role="alert" id={`${uid}-car-err`}>{err('vehicle_id') ?? ''}</p></div>
          {kinds && <div className="field"><label className="label" htmlFor={`${uid}-kind`}>Kind</label>
            <select className="select" id={`${uid}-kind`} value={kind} onChange={(e) => setKind(e.target.value)} data-testid="invoice-kind">
              <option value="custom">Invoice (any amount: registration fee, other fees)</option><option value="upfront">First and last month</option>
              <option value="tracker_install">Tracker install</option><option value="adjustment">Adjustment</option></select></div>}
        </div>)}
      <div className="field-row">
        <div className="field"><label className="label" htmlFor={`${uid}-title`}>Title (optional)</label>
          <input className="input" id={`${uid}-title`} value={title} onChange={(e) => setTitle(e.target.value)} placeholder="For example: Registration fee" data-testid="invoice-title" /></div>
        <div className="field"><label className="label" htmlFor={`${uid}-due`}>Due date (optional)</label>
          <input className="input" id={`${uid}-due`} type="date" value={due} onChange={(e) => setDue(e.target.value)} aria-describedby={`${uid}-due-h`} data-testid="invoice-due" />
          <p className="hint" id={`${uid}-due-h`}>Empty: 7 days after it is issued (Program settings).</p></div>
      </div>
      <fieldset className="stack"><legend className="label">Lines</legend>
        <ol className="ob-lines" data-testid="invoice-lines">{rows.map((r, i) => (
          <li key={i} className="ob-line" data-testid="invoice-line">
            <div className={`field ob-line__desc${err(`line-${i}-description`) ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-d${i}`}>Description</label>
              <input className="input" id={`${uid}-d${i}`} value={r.description} onChange={(e) => set(i, 'description', e.target.value)} data-testid="line-description" aria-describedby={`${uid}-d${i}-e`} />
              <p className="error" role="alert" id={`${uid}-d${i}-e`}>{err(`line-${i}-description`) ?? ''}</p></div>
            <div className={`field ob-line__qty${err(`line-${i}-quantity`) ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-q${i}`}>Quantity</label>
              <input className="input" id={`${uid}-q${i}`} inputMode="decimal" value={r.quantity} onChange={(e) => set(i, 'quantity', e.target.value)} data-testid="line-quantity" aria-describedby={`${uid}-q${i}-e`} />
              <p className="error" role="alert" id={`${uid}-q${i}-e`}>{err(`line-${i}-quantity`) ?? ''}</p></div>
            <div className={`field ob-line__unit${err(`line-${i}-unit`) ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-u${i}`}>Unit amount ($)</label>
              <input className="input" id={`${uid}-u${i}`} inputMode="decimal" value={r.unit} onChange={(e) => set(i, 'unit', e.target.value)} placeholder="0.00" data-testid="line-unit" aria-describedby={`${uid}-u${i}-e`} />
              <p className="error" role="alert" id={`${uid}-u${i}-e`}>{err(`line-${i}-unit`) ?? ''}</p></div>
            <label className="check ob-line__hst" htmlFor={`${uid}-h${i}`}><input type="checkbox" id={`${uid}-h${i}`} checked={r.hst} onChange={(e) => set(i, 'hst', e.target.checked)} data-testid="line-hst" /><span>HST</span></label>
            <span className="ob-line__amt" aria-label="Line amount">{money(amount(r), { cents: true })}</span>
            <div className="field ob-line__note"><label className="label" htmlFor={`${uid}-n${i}`}>Note (optional)</label>
              <input className="input" id={`${uid}-n${i}`} value={r.note} onChange={(e) => set(i, 'note', e.target.value)} /></div>
            {rows.length > 1 && <button type="button" className="btn btn--quiet btn--sm" onClick={() => setRows(rows.filter((_, j) => j !== i))} aria-label={`Remove line ${i + 1}`}>Remove</button>}
          </li>))}
        </ol>
        {kept.length > 0 && <p className="small muted">Kept as they are: {kept.map((l) => `${l.description} (${money(Math.round(Number(l.quantity) * l.unit_amount_cents), { cents: true })})`).join(', ')}.</p>}
        <div className="row"><button type="button" className="btn btn--ghost btn--sm" onClick={() => setRows([...rows, { description: '', quantity: '1', unit: '', hst: true, note: '' }])} data-testid="line-add">Add a line</button></div>
        {err('lines') && <p className="error" role="alert">{err('lines')}</p>}
      </fieldset>
      <dl className="ob-totals" aria-label="Totals"><div><dt>Before HST</dt><dd data-testid="invoice-subtotal">{money(sub, { cents: true })}</dd></div><div><dt>HST</dt><dd>{money(hst, { cents: true })}</dd></div><div><dt>Total</dt><dd data-testid="invoice-total"><b>{money(sub + hst, { cents: true })}</b></dd></div></dl>
      <div className="field"><label className="label" htmlFor={`${uid}-notes`}>Notes on the invoice (optional; the owner reads them)</label>
        <textarea className="input" id={`${uid}-notes`} rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} data-testid="invoice-notes" /></div>
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <button className="btn btn--ghost" type="submit" disabled={a.pending} data-testid="invoice-save">{a.pending ? 'Saving' : 'Save as draft'}</button>
        <button className="btn btn--primary" type="button" disabled={a.pending} onClick={() => { if (window.confirm('Issue this invoice? The owner is emailed and an issued invoice cannot be edited.')) save(true); }} data-testid="invoice-save-issue">Save and issue</button>
      </div>
    </form>
  );
}
