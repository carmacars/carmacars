'use client';
import { useId, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import type { ActionResult } from '@/features/forms/schemas';
import { recordManualPayment, recordPaperSignature, voidManualPayment, voidPaperSignature } from '@/server/actions/manual-records';

// Payments received another way and signatures on paper (migration 0044): the forms Admins and staff use on the owner,
// invoice, booking, investor and staff screens, and the lists of what was recorded, each with its undo (void, with a reason).
const METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['cheque', 'Cheque'], ['cash', 'Cash'], ['bank_transfer', 'Bank transfer'], ['other', 'Other']];
const PURPOSES: Array<[string, string]> = [['post_rental', 'Charges after the rental'], ['booking_total', 'The booking total'], ['extension', 'An extension'], ['toll_ticket', 'A toll or ticket'], ['damage', 'Damage'], ['deductible', 'The deductible'], ['other', 'Something else']];
const REF_HINT: Record<string, string> = { e_transfer: 'The e-Transfer reference number.', cheque: 'The cheque number.', bank_transfer: 'The bank transfer reference.', cash: 'A receipt number, if you gave one (optional).', other: 'Any reference (optional).' };
const day = (iso: string | null | undefined) => (iso ? new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`)) : '');

type Res = { ok: true } | { ok: false; message: string; fieldErrors?: Record<string, string> } | null;
const Problem = ({ res }: { res: Res }) => (res && !res.ok ? <p className="alert alert--error" role="alert"><span>{res.message}</span></p> : null);
function Field({ id, label, err, hint, children }: { id: string; label: string; err?: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className={`field${err ? ' has-error' : ''}`}>
      <label className="label" htmlFor={id}>{label}</label>
      {children}
      {hint && <p className="hint" id={`${id}-hint`}>{hint}</p>}
      <p className="error" role="alert" id={`${id}-err`}>{err ?? ''}</p>
    </div>
  );
}

/** Record a payment received another way on an owner invoice (invoice) or a renter booking (booking). */
export function ManualPaymentForm({ invoice, booking, number, balance, today, refresh = [], purpose, settlesPayment, label = 'Record payment', startOpen = false, prefix = 'ad-off' }: {
  prefix?: string; invoice?: string; booking?: string; number: string; balance: number; today: string; refresh?: string[]; purpose?: string; settlesPayment?: string; label?: string; startOpen?: boolean;
}) {
  const router = useRouter();
  const a = useAct<{ invoice_status: string | null; balance_cents: number | null; repeat: boolean }>();
  const [open, setOpen] = useState(startOpen);
  const [method, setMethod] = useState('e_transfer');
  const form = useRef<HTMLFormElement>(null);
  const id = (k: string) => `${prefix}-${number}-${k}`;
  const desc = (k: string, hint = false) => `${id(k)}-err${hint ? ` ${id(k)}-hint` : ''}`;
  if (!open) return <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid={prefix === 'ad-off' ? `offline-${number}` : `${prefix}-${number}`}>{label}</button>;
  return (
    <form ref={form} className="stack pt-sheet" noValidate aria-label={`Record a payment for ${number}`} data-testid="manual-payment-form"
      onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); a.run(() => recordManualPayment(fd), (r) => { if (r.ok) { router.refresh(); form.current?.reset(); } }); }}>
      {invoice && <input type="hidden" name="invoice" value={invoice} />}
      {booking && <input type="hidden" name="booking" value={booking} />}
      {purpose && <input type="hidden" name="purpose" value={purpose} />}
      {booking && !purpose && !settlesPayment && (
        <Field id={id('for')} label="What it pays" err={a.err('purpose')}>
          <select className="select" id={id('for')} name="purpose" defaultValue="post_rental">{PURPOSES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        </Field>
      )}
      {settlesPayment && <input type="hidden" name="settles_payment" value={settlesPayment} />}
      <input type="hidden" name="refresh" value={refresh.join(',')} />
      <div className="field-row">
        <Field id={id('m')} label="Paid by" err={a.err('method')}>
          <select className="select" id={id('m')} name="method" value={method} onChange={(e) => setMethod(e.target.value)}>{METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
        </Field>
        <Field id={id('on')} label="Date received" err={a.err('received_on')}><input className="input" id={id('on')} name="received_on" type="date" defaultValue={today} max={today} aria-describedby={desc('on')} /></Field>
      </div>
      <div className="field-row">
        <Field id={id('ref')} label={method === 'cheque' ? 'Cheque number' : 'Reference'} err={a.err('reference')} hint={REF_HINT[method]}><input className="input" id={id('ref')} name="reference" aria-describedby={desc('ref', true)} /></Field>
        <Field id={id('amt')} label="Amount ($)" err={a.err('amount')} hint={balance > 0 ? `Leave empty for the full ${invoice ? 'balance' : 'amount'}, ${money(balance, { cents: true })}. A smaller amount is a partial payment.` : 'The amount received.'}>
          <input className="input" id={id('amt')} name="amount" inputMode="decimal" placeholder={balance > 0 ? (balance / 100).toFixed(2) : undefined} aria-describedby={desc('amt', true)} /></Field>
      </div>
      <Field id={id('proof')} label="Proof (optional)" err={a.err('proof')} hint="A screenshot of the e-Transfer or a photo of the cheque. PDF, JPEG or PNG."><input className="input" id={id('proof')} name="proof" type="file" accept="application/pdf,image/jpeg,image/png" aria-describedby={desc('proof', true)} /></Field>
      <Field id={id('note')} label={method === 'other' ? 'How it was paid' : 'Note (optional)'} err={a.err('note')}><input className="input" id={id('note')} name="note" aria-describedby={desc('note')} /></Field>
      <Problem res={a.res} />
      {a.res?.ok && <p className="alert alert--ok" role="status" data-testid="manual-payment-done"><span>{a.res.data.repeat ? 'That payment was already recorded.' : a.res.data.invoice_status === 'paid' || a.res.data.balance_cents === 0 ? (invoice ? 'Recorded. The invoice is paid and the owner gets a receipt.' : 'Recorded.') : `Recorded. ${money(a.res.data.balance_cents ?? 0, { cents: true })} is still owing.`}</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending}>{a.pending ? 'Recording' : 'Record payment'}</button><button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Close</button></div>
    </form>
  );
}

export interface ManualRow { id: string; method: string; method_label: string; amount_cents: number; received_on: string; reference: string | null; voided_at: string | null; void_reason?: string | null; note?: string | null; proof_document_id?: string | null; recorded_by_name?: string | null }

/** The payments recorded by hand on one invoice or booking, with Void (Admins). */
export function ManualPaymentList({ rows, canVoid, docBase = '/admin/documents', refresh = [] }: { rows: ManualRow[]; canVoid: boolean; docBase?: string; refresh?: string[] }) {
  if (!rows?.length) return null;
  return (
    <ul className="mr-list" data-testid="manual-payments">
      {rows.map((m) => (
        <li key={m.id} className={m.voided_at ? 'is-void' : undefined}>
          <span><b>{money(m.amount_cents, { cents: true })}</b> by {m.method_label} on {day(m.received_on)}{m.reference ? `, ref. ${m.reference}` : ''}{m.recorded_by_name ? `. Recorded by ${m.recorded_by_name}` : ''}{m.note ? `. ${m.note}` : ''}</span>
          {m.proof_document_id && <a className="link small" href={`${docBase}/${m.proof_document_id}`} target="_blank" rel="noreferrer">Proof</a>}
          {m.voided_at ? <span className="badge badge--outline">Voided{m.void_reason ? `: ${m.void_reason}` : ''}</span> : canVoid ? <VoidButton what="payment" onVoid={(r) => voidManualPayment(m.id, r, refresh)} /> : null}
        </li>
      ))}
    </ul>
  );
}

function VoidButton({ what, onVoid }: { what: 'payment' | 'signature'; onVoid: (reason: string) => Promise<ActionResult<null>> }) {
  const router = useRouter();
  const a = useAct<null>();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const uid = `void-${useId().replace(/[^\w-]/g, '')}`;
  if (!open) return <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(true)} data-testid={`void-${what}`}>Void</button>;
  return (
    <form className="row mr-void" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => onVoid(reason), (r) => { if (r.ok) { setOpen(false); router.refresh(); } }); }}>
      <label className="vh" htmlFor={uid}>Why is this {what} voided?</label>
      <input className="input" id={uid} value={reason} onChange={(e) => setReason(e.target.value)} placeholder={what === 'payment' ? 'Why? For example: the cheque was returned' : 'Why? For example: wrong document'} aria-invalid={!!a.err('reason') || undefined} />
      <button className="btn btn--ghost btn--sm" type="submit" disabled={a.pending}>{a.pending ? 'Voiding' : `Void the ${what}`}</button>
      <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button>
      {a.res && !a.res.ok && <p className="error" role="alert">{a.res.fieldErrors?.reason ?? a.res.message}</p>}
    </form>
  );
}

export interface PaperDoc { doc_type: string; target_id: string; label: string; signer?: string; witnesses?: 0 | 1 | 2 }

/** Record a signature on paper: which document, who signed, the date, any witness, a note, and the scan. */
export function PaperSignatureForm({ docs, today, refresh = [], label = 'Record paper signature', startOpen = false, testId = 'paper-signature' }: { docs: PaperDoc[]; today: string; refresh?: string[]; label?: string; startOpen?: boolean; testId?: string }) {
  const router = useRouter();
  const a = useAct<{ id: string }>();
  const [open, setOpen] = useState(startOpen);
  const [pick, setPick] = useState(0);
  const form = useRef<HTMLFormElement>(null);
  const uid = `ps-${useId().replace(/[^\w-]/g, '')}`;
  const id = (k: string) => `${uid}-${k}`;
  if (!docs.length) return null;
  const doc = docs[pick] ?? docs[0]!;
  if (!open) return <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid={testId}>{label}</button>;
  return (
    <form ref={form} className="stack pt-sheet" noValidate aria-label="Record a paper signature" data-testid="paper-signature-form"
      onSubmit={(e) => { e.preventDefault(); const fd = new FormData(e.currentTarget); a.run(() => recordPaperSignature(fd), (r) => { if (r.ok) { router.refresh(); form.current?.reset(); } }); }}>
      <input type="hidden" name="doc_type" value={doc.doc_type} />
      <input type="hidden" name="target_id" value={doc.target_id} />
      <input type="hidden" name="refresh" value={refresh.join(',')} />
      {docs.length > 1
        ? <Field id={id('doc')} label="Document" err={a.err('doc_type')}><select className="select" id={id('doc')} value={pick} onChange={(e) => setPick(Number(e.target.value))}>{docs.map((d, i) => <option key={`${d.doc_type}-${d.target_id}-${i}`} value={i}>{d.label}</option>)}</select></Field>
        : <p className="small"><b>{doc.label}</b></p>}
      <div className="field-row">
        <Field id={id('who')} label="Signed by" err={a.err('signer_name')}><input key={`who-${pick}`} className="input" id={id('who')} name="signer_name" defaultValue={doc.signer ?? ''} autoComplete="off" /></Field>
        <Field id={id('on')} label="Date signed" err={a.err('signed_on')}><input className="input" id={id('on')} name="signed_on" type="date" defaultValue={today} max={today} /></Field>
      </div>
      {(doc.witnesses ?? 0) > 0 && (
        <div className="field-row">
          <Field id={id('w1')} label={doc.witnesses === 2 ? 'First witness' : 'Witness'} err={a.err('witness_1_name')}><input className="input" id={id('w1')} name="witness_1_name" /></Field>
          {doc.witnesses === 2 && <Field id={id('w2')} label="Second witness" err={a.err('witness_2_name')}><input className="input" id={id('w2')} name="witness_2_name" /></Field>}
        </div>
      )}
      {(doc.witnesses ?? 0) === 0 && <Field id={id('w1')} label="Witness (optional)"><input className="input" id={id('w1')} name="witness_1_name" /></Field>}
      {doc.doc_type === 'investment_agreement' && (
        <div className="field-row">
          <Field id={id('ex')} label="Exemption"><select className="select" id={id('ex')} name="exemption_category" defaultValue=""><option value="">As on the agreement</option><option value="accredited_investor">Accredited investor</option><option value="offering_memorandum_eligible">Offering memorandum, eligible investor</option></select></Field>
          <Field id={id('la')} label="Legal advice"><select className="select" id={id('la')} name="legal_advice_choice" defaultValue=""><option value="">As on the agreement</option><option value="obtained">Obtained</option><option value="declined">Chose not to</option></select></Field>
        </div>
      )}
      <Field id={id('scan')} label="Scan of the signed document" err={a.err('scan')} hint="Every signed page, as one PDF, or a photo. Kept privately with the person's documents."><input className="input" id={id('scan')} name="scan" type="file" accept="application/pdf,image/jpeg,image/png" aria-describedby={`${id('scan')}-hint`} /></Field>
      <Field id={id('note')} label="Note (optional)"><input className="input" id={id('note')} name="note" /></Field>
      <Problem res={a.res} />
      {a.res?.ok && <p className="alert alert--ok" role="status" data-testid="paper-signature-done"><span>Recorded. It now counts as signed.</span></p>}
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending}>{a.pending ? 'Recording' : 'Record signature'}</button><button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Close</button></div>
    </form>
  );
}

export interface PaperRow { id: string; title: string; vehicle_name: string | null; document_id: string | null; signer_name: string; signed_on: string; witness_1_name: string | null; witness_2_name: string | null; note: string | null; recorded_by_name: string | null; voided_at: string | null; void_reason: string | null }

export function PaperSignatureList({ rows, canVoid, docBase = '/admin/documents', refresh = [] }: { rows: PaperRow[]; canVoid: boolean; docBase?: string; refresh?: string[] }) {
  if (!rows?.length) return <p className="small muted">No paper signatures recorded.</p>;
  return (
    <ul className="mr-list" data-testid="paper-signatures">
      {rows.map((p) => (
        <li key={p.id} className={p.voided_at ? 'is-void' : undefined}>
          <span><b>{p.title}</b>{p.vehicle_name ? `, ${p.vehicle_name}` : ''}: signed by {p.signer_name} on {day(p.signed_on)}{[p.witness_1_name, p.witness_2_name].filter(Boolean).length ? `, witnessed by ${[p.witness_1_name, p.witness_2_name].filter(Boolean).join(' and ')}` : ''}{p.recorded_by_name ? `. Recorded by ${p.recorded_by_name}` : ''}{p.note ? `. ${p.note}` : ''}</span>
          {p.document_id && <a className="link small" href={`${docBase}/${p.document_id}`} target="_blank" rel="noreferrer">Scan</a>}
          {p.voided_at ? <span className="badge badge--outline">Voided{p.void_reason ? `: ${p.void_reason}` : ''}</span> : canVoid ? <VoidButton what="signature" onVoid={(r) => voidPaperSignature(p.id, r, refresh)} /> : null}
        </li>
      ))}
    </ul>
  );
}
