'use client';
import './insurance.css';
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { TypedInput } from '@/components/DateInput';
import { insuranceDo } from '@/server/actions/insurance';
import { diffVersions, lineAmount, totals, type BillTo, type Line, type Snapshot } from './model';

type Row = { description: string; quantity: string; rate: string; amount: string; taxable: boolean };
export interface Working { lines: Line[]; hst_cents: number; notes?: string | null; period_start?: string | null; period_end?: string | null; invoice_date?: string | null; due_date?: string | null; bill_to?: BillTo | null; claim_number?: string | null }

const dollars = (c: number | null | undefined) => (c === null || c === undefined ? '' : (c / 100).toFixed(2));
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); if (!t) return null; const n = Number(t); return Number.isFinite(n) ? Math.round(n * 100) : NaN; };
const money = (c: number) => `${c < 0 ? '-' : ''}$${(Math.abs(c) / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`;
const toRow = (l: Line): Row => ({ description: l.description, quantity: l.quantity == null ? '' : String(l.quantity), rate: dollars(l.rate_cents), amount: dollars(l.amount_cents), taxable: l.taxable !== false });

// The invoice of an insurance replacement (5120): every field of its next version, editable (the lines with their days and
// rate, the fees such as the winter tire fee, the HST, the notes, the dates, who it is billed to). Save keeps it; Send makes
// it a version (an estimate bills nothing, an invoice is what the insurer owes from then on), as many times as needed.
export function InvoiceEditor({ booking, working, current, hstBps, status, sentVersions, mayMoney, fromBooking, adjusterEmail }: {
  booking: string; working: Working; current: Snapshot | null; hstBps: number; status: string | null; sentVersions: number; mayMoney: boolean; fromBooking: Working; adjusterEmail: string | null;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [rows, setRows] = useState<Row[]>(() => (working.lines?.length ? working.lines : fromBooking.lines).map(toRow));
  const [hstTyped, setHstTyped] = useState<string>('');
  const [meta, setMeta] = useState({ notes: working.notes ?? '', period_start: working.period_start ?? '', period_end: working.period_end ?? '', invoice_date: working.invoice_date ?? '',
    due_date: working.due_date ?? '', claim_number: working.claim_number ?? '', bt_name: working.bill_to?.name ?? '', bt_attention: working.bill_to?.attention ?? '',
    bt_email: working.bill_to?.email ?? '', bt_address: working.bill_to?.address ?? '' });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [dirty, setDirty] = useState(false);

  const lines: Line[] = useMemo(() => rows.map((r) => {
    const q = r.quantity.trim() ? Number(r.quantity) : null; const rate = cents(r.rate); const a = cents(r.amount);
    return { description: r.description.trim(), quantity: q, rate_cents: rate, amount_cents: a ?? lineAmount({ quantity: q, rate_cents: rate }), taxable: r.taxable };
  }), [rows]);
  const typed = hstTyped.trim() ? cents(hstTyped) : null;
  const t = totals(lines, hstBps, typed === null || Number.isNaN(typed) ? (dirty ? null : working.hst_cents) : typed);
  const next: Snapshot = { lines, ...t, notes: meta.notes || null, period_start: meta.period_start || null, period_end: meta.period_end || null, invoice_date: meta.invoice_date || null,
    due_date: meta.due_date || null, claim_number: meta.claim_number || null,
    bill_to: { name: meta.bt_name || null, attention: meta.bt_attention || null, email: meta.bt_email || null, address: meta.bt_address || null } };
  const changes = current ? diffVersions(current, next) : [];

  const edit = (i: number, k: keyof Row) => (e: { target: { value: string; checked?: boolean } }) => {
    setDirty(true);
    setRows((x) => x.map((r, j) => {
      if (j !== i) return r;
      const n = { ...r, [k]: k === 'taxable' ? Boolean(e.target.checked) : e.target.value } as Row;
      // days or rate changed: the amount follows them
      if ((k === 'quantity' || k === 'rate') && n.quantity.trim() && n.rate.trim()) { const v = lineAmount({ quantity: Number(n.quantity), rate_cents: cents(n.rate) }); if (Number.isFinite(v)) n.amount = dollars(v); }
      return n;
    }));
  };
  const setM = (k: keyof typeof meta) => (e: { target: { value: string } }) => { setDirty(true); setMeta((x) => ({ ...x, [k]: e.target.value })); };
  const bad = rows.findIndex((r) => !r.description.trim() || Number.isNaN(cents(r.amount) ?? 0) || Number.isNaN(cents(r.rate) ?? 0));

  const payload = () => ({ booking, lines: lines.map((l) => ({ ...l, quantity: l.quantity ?? undefined, rate_cents: l.rate_cents ?? undefined })),
    hst_cents: typed === null || Number.isNaN(typed) ? null : typed, notes: meta.notes, period_start: meta.period_start || null, period_end: meta.period_end || null,
    invoice_date: meta.invoice_date || null, due_date: meta.due_date || null, claim_number: meta.claim_number,
    bill_to: { name: meta.bt_name, attention: meta.bt_attention, email: meta.bt_email, address: meta.bt_address } });
  const saveNow = async () => {
    if (bad >= 0) { setMsg({ ok: false, text: `Line ${bad + 1}: a description and amounts in dollars.` }); return false; }
    const r = await insuranceDo('insurer_invoice_save', payload());
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return false; }
    setDirty(false);
    return true;
  };
  const save = () => start(async () => { if (await saveNow()) { setMsg({ ok: true, text: sentVersions ? 'Saved. The insurer still has the last version until you send this one.' : 'Saved.' }); router.refresh(); } });
  const send = (kind: 'invoice' | 'estimate', email: boolean) => start(async () => {
    const to = meta.bt_email || adjusterEmail || 'the insurer\'s billing email';
    const word = kind === 'estimate' ? 'an estimate (it bills nothing)' : 'the invoice (what the insurer owes from now on)';
    if (!window.confirm(`Send ${word}, version ${sentVersions + 1}, for ${money(t.total_cents)}${email ? ` by email to ${to}` : ', recorded as sent another way (no email)'}?`)) return;
    if (dirty && !(await saveNow())) return;
    const r = await insuranceDo<{ version: number; to: string | null }>('insurer_invoice_send', { booking, kind, email });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Version ${r.data.version} sent${r.data.to ? ` to ${r.data.to}` : ''}.` });
    router.refresh();
  });
  const fromTheBooking = () => start(async () => {
    const r = await insuranceDo('insurer_invoice_save', { booking, from_booking: true });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setRows(fromBooking.lines.map(toRow)); setHstTyped(''); setDirty(false);
    setMsg({ ok: true, text: 'The lines are the booking\'s figures now (its days, rate and fees). Check them, then send.' });
    router.refresh();
  });

  const input = (k: keyof typeof meta, label: string, type = 'text') => (
    <label className="ins-field" key={k}><span>{label}</span><TypedInput className="input" type={type} value={meta[k]} onChange={setM(k)} data-testid={`inv-${k}`} /></label>);

  return (
    <div className="stack" data-testid="inv-editor">
      <div className="ins-lines" role="group" aria-label="Lines">
        {rows.map((r, i) => (
          <div className="ins-line" key={i} data-testid="inv-line">
            <label className="ins-field"><span>Description</span><input className="input" value={r.description} onChange={edit(i, 'description')} data-testid="inv-desc" /></label>
            <label className="ins-field"><span>Days or qty</span><input className="input" inputMode="decimal" value={r.quantity} onChange={edit(i, 'quantity')} data-testid="inv-qty" /></label>
            <label className="ins-field"><span>Rate ($)</span><input className="input" inputMode="decimal" value={r.rate} onChange={edit(i, 'rate')} data-testid="inv-rate" /></label>
            <label className="ins-field"><span>Amount ($)</span><input className="input" inputMode="decimal" value={r.amount} onChange={edit(i, 'amount')} data-testid="inv-amount" /></label>
            <label className="ins-line__tax"><input type="checkbox" checked={r.taxable} onChange={edit(i, 'taxable')} /> HST</label>
            <button className="btn btn--quiet btn--sm" type="button" aria-label={`Remove line ${i + 1}`} onClick={() => { setDirty(true); setRows((x) => x.filter((_, j) => j !== i)); }} disabled={rows.length < 2} title={rows.length < 2 ? 'An invoice keeps at least one line: add another line first' : undefined}>Remove</button>
          </div>))}
        <div className="ins-actions">
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setDirty(true); setRows((x) => [...x, { description: '', quantity: '', rate: '', amount: '', taxable: true }]); }} data-testid="inv-add-line">Add a line</button>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setDirty(true); setRows((x) => [...x, { description: 'Winter tire fee', quantity: '', rate: '', amount: '', taxable: true }]); }} data-testid="inv-add-winter">Add the winter tire fee</button>
          <button className="btn btn--quiet btn--sm" type="button" onClick={fromTheBooking} disabled={pending} data-testid="inv-from-booking">Start from the booking&apos;s figures</button>
        </div>
      </div>
      <div className="ins-totals" data-testid="inv-totals">
        <span>Before HST</span><span>{money(t.amount_cents)}</span>
        <label htmlFor="inv-hst">HST {hstTyped.trim() ? '(typed)' : `(${hstBps / 100}% of the taxable lines)`}</label>
        <input id="inv-hst" className="input" inputMode="decimal" placeholder={dollars(t.hst_cents)} value={hstTyped} onChange={(e) => { setDirty(true); setHstTyped(e.target.value); }} data-testid="inv-hst" style={{ maxWidth: '8rem' }} />
        <b>Total</b><b data-testid="inv-total">{money(t.total_cents)}</b>
      </div>
      <div className="ins-grid">
        {input('invoice_date', 'Invoice date', 'date')}{input('due_date', 'Due date', 'date')}
        {input('period_start', 'Rental from', 'date')}{input('period_end', 'Rental to', 'date')}
        {input('claim_number', 'Claim number')}
        {input('bt_name', 'Bill to (empty: the insurer)')}{input('bt_attention', 'Attention (empty: the adjuster)')}
        {input('bt_email', 'Send to email (empty: the adjuster)', 'email')}{input('bt_address', 'Bill-to address')}
        <label className="ins-field ins-grid--wide"><span>Notes on the invoice</span><textarea className="input" value={meta.notes} onChange={setM('notes')} data-testid="inv-notes" /></label>
      </div>
      {current && changes.length > 0 && (
        <div className="ins-found" data-testid="inv-changes"><p className="small"><b>Not sent yet:</b> what this version changes from the last one sent.</p>
          <ul className="ins-diff">{changes.map((c) => <li key={c.label}><span>{c.label}</span><span><del>{c.before}</del> to <ins>{c.after}</ins></span></li>)}</ul></div>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="inv-msg"><span>{msg.text}</span></p>}
      <div className="ins-actions">
        <button className="btn btn--ghost" type="button" onClick={save} disabled={pending} data-testid="inv-save">Save</button>
        {mayMoney && status !== 'written_off' && <>
          <button className="btn btn--primary" type="button" onClick={() => send('invoice', true)} disabled={pending} data-testid="inv-send-invoice">{sentVersions && status !== 'draft' ? 'Send the new invoice' : 'Send the invoice'}</button>
          <button className="btn btn--ghost" type="button" onClick={() => send('estimate', true)} disabled={pending} data-testid="inv-send-estimate">Send as an estimate</button>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => send('invoice', false)} disabled={pending} data-testid="inv-mark-sent">Record as sent (no email)</button></>}
        {!mayMoney && <span className="small muted">Finance or an Admin sends it.</span>}
      </div>
    </div>
  );
}
