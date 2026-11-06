'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo } from '@/server/actions/staff-tools';
import { money } from '@/lib/format';
import { DEFAULT_LINE, KINDS, linePayload, totals, type DraftLine } from './model';

// The invoice builder (migration 0547): the partner, the claim it is for, the lines (editable wording, quantity and
// amount, or a percentage of the partner's claim, tow or storage total), HST per line, the due date and reminders.
// Saved as a draft; Send numbers it and emails the partner.
export interface Partner { id: string; name: string; kind: string; default_kickback_bps: number | null; email: string | null }
export interface InvoiceIn {
  id?: string; partner_id?: string; kind?: string; claim_number?: string | null; insurer_name?: string | null; vehicle?: string | null; renter_name?: string | null;
  booking_number?: string | null; partner_total_cents?: number | null; kickback_bps?: number | null; due_on?: string | null; notes?: string | null;
  remind_before_days?: number; remind_after_days?: number;
  lines?: Array<{ description: string; quantity: number; unit_cents: number; percent_bps: number | null; base_cents: number | null; hst: boolean }>;
}
const d = (c: number | null | undefined) => (c ? (c / 100).toFixed(2) : '');
const kindOfPartner = (k: string) => (k === 'tow_truck' ? 'towing' : k === 'body_shop' ? 'repair' : 'other');

export function Builder({ partners, inv, refresh, base }: { partners: Partner[]; inv?: InvoiceIn; refresh: string[]; base: string }) {
  const router = useRouter();
  const [f, setF] = useState({ partner_id: inv?.partner_id ?? '', kind: inv?.kind ?? 'repair', claim_number: inv?.claim_number ?? '', insurer_name: inv?.insurer_name ?? '',
    vehicle: inv?.vehicle ?? '', renter_name: inv?.renter_name ?? '', booking: inv?.booking_number ?? '', partner_total: d(inv?.partner_total_cents), due_on: inv?.due_on ?? '',
    notes: inv?.notes ?? '', remind_before_days: String(inv?.remind_before_days ?? 3), remind_after_days: String(inv?.remind_after_days ?? 7) });
  const [lines, setLines] = useState<DraftLine[]>(() => inv?.lines?.length ? inv.lines.map((l) => ({ description: l.description, quantity: String(l.quantity), unit: d(l.unit_cents),
    percent: l.percent_bps != null ? String(l.percent_bps / 100) : '', base: d(l.base_cents), hst: l.hst })) : [{ description: DEFAULT_LINE.repair ?? 'Outsourced repair services', quantity: '1', unit: '', percent: '', base: '', hst: true }]);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (k: keyof typeof f) => (v: string) => setF((s) => ({ ...s, [k]: v }));
  const setLine = (i: number, p: Partial<DraftLine>) => setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...p } : l)));
  const t = totals(lines);
  const pickPartner = (id: string) => {
    const pt = partners.find((p) => p.id === id);
    const kind = pt ? kindOfPartner(pt.kind) : f.kind;
    setF((s) => ({ ...s, partner_id: id, kind }));
    // the partner's usual kickback as a percentage line of its total, when the first line is still the default
    if (pt?.default_kickback_bps != null) setLines((ls) => ls.length === 1 && !ls[0]!.unit && !ls[0]!.percent ? [{ ...ls[0]!, description: DEFAULT_LINE[kind] ?? ls[0]!.description, percent: String(pt.default_kickback_bps! / 100), base: f.partner_total }] : ls);
  };
  const save = (send: boolean) => start(async () => {
    setMsg(null);
    const r = await staffDo<{ id: string }>('partner_invoice_save', { id: inv?.id, ...f, partner_total_cents: f.partner_total ? Math.round(Number(f.partner_total.replace(/[$,]/g, '')) * 100) : null,
      lines: lines.map((l) => linePayload({ ...l, base: l.percent ? (l.base || f.partner_total) : l.base })) }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    if (send) {
      const s = await staffDo<{ invoice_number: string; sent_to: string }>('partner_invoice_send', { id: r.data.id }, refresh);
      setMsg(s.ok ? { ok: true, text: `Invoice ${s.data.invoice_number} sent to ${s.data.sent_to}.` } : { ok: false, text: `Saved as a draft, not sent: ${s.message}` });
    } else setMsg({ ok: true, text: 'Saved as a draft.' });
    router.push(`${base}${base.includes('?') ? '&' : '?'}invoice=${r.data.id}`);
    router.refresh();
  });
  return (
    <form className="stack ad-form" data-testid="pi-builder" onSubmit={(e) => { e.preventDefault(); save(false); }}>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="pi-partner">Partner</label>
          <select className="select" id="pi-partner" required value={f.partner_id} onChange={(e) => pickPartner(e.target.value)} data-testid="pi-partner">
            <option value="">Choose</option>{partners.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-kind">For</label>
          <select className="select" id="pi-kind" value={f.kind} onChange={(e) => set('kind')(e.target.value)}>{KINDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        {([['claim_number', 'Claim number'], ['insurer_name', 'Insurer'], ['vehicle', 'Vehicle'], ['renter_name', 'Customer (renter)'], ['booking', 'Booking number (optional)']] as const).map(([k, l]) => (
          <div className="field ad-field" key={k}><label className="label" htmlFor={`pi-${k}`}>{l}</label><input className="input" id={`pi-${k}`} value={f[k]} onChange={(e) => set(k)(e.target.value)} data-testid={`pi-${k}`} /></div>))}
        <div className="field ad-field"><label className="label" htmlFor="pi-ptotal">The partner&apos;s claim, tow or storage total ($)</label>
          <input className="input" id="pi-ptotal" inputMode="decimal" value={f.partner_total} onChange={(e) => set('partner_total')(e.target.value)} data-testid="pi-partner-total" /></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-due">Due (empty: set when sent)</label><input className="input" id="pi-due" type="date" value={f.due_on} onChange={(e) => set('due_on')(e.target.value)} /></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-rb">Reminder, days before due (0: none)</label><input className="input" id="pi-rb" inputMode="numeric" value={f.remind_before_days} onChange={(e) => set('remind_before_days')(e.target.value)} /></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-ra">Reminder, days after due (0: none)</label><input className="input" id="pi-ra" inputMode="numeric" value={f.remind_after_days} onChange={(e) => set('remind_after_days')(e.target.value)} /></div>
      </div>
      <fieldset className="stack"><legend className="label">Lines</legend>
        {lines.map((l, i) => (
          <div key={i} className="ad-fields" data-testid={`pi-line-${i}`}>
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`pi-l${i}-d`}>Description</label><input className="input" id={`pi-l${i}-d`} value={l.description} onChange={(e) => setLine(i, { description: e.target.value })} /></div>
            <div className="field ad-field"><label className="label" htmlFor={`pi-l${i}-p`}>% of the partner&apos;s total (or empty)</label><input className="input" id={`pi-l${i}-p`} inputMode="decimal" value={l.percent} onChange={(e) => setLine(i, { percent: e.target.value })} data-testid={`pi-l${i}-percent`} /></div>
            {l.percent ? <div className="field ad-field"><label className="label" htmlFor={`pi-l${i}-b`}>Of ($)</label><input className="input" id={`pi-l${i}-b`} inputMode="decimal" value={l.base || f.partner_total} onChange={(e) => setLine(i, { base: e.target.value })} /></div>
              : <><div className="field ad-field"><label className="label" htmlFor={`pi-l${i}-q`}>Quantity</label><input className="input" id={`pi-l${i}-q`} inputMode="decimal" value={l.quantity} onChange={(e) => setLine(i, { quantity: e.target.value })} /></div>
                <div className="field ad-field"><label className="label" htmlFor={`pi-l${i}-u`}>Amount ($)</label><input className="input" id={`pi-l${i}-u`} inputMode="decimal" value={l.unit} onChange={(e) => setLine(i, { unit: e.target.value })} data-testid={`pi-l${i}-amount`} /></div></>}
            <label className="check" htmlFor={`pi-l${i}-h`}><input id={`pi-l${i}-h`} type="checkbox" checked={l.hst} onChange={(e) => setLine(i, { hst: e.target.checked })} /> <span>HST 13%</span></label>
            {lines.length > 1 && <button className="btn btn--quiet btn--sm" type="button" onClick={() => setLines((ls) => ls.filter((_, j) => j !== i))}>Remove</button>}
          </div>))}
        <button className="btn btn--ghost btn--sm" type="button" onClick={() => setLines((ls) => [...ls, { description: DEFAULT_LINE[f.kind] ?? 'Outsourced services', quantity: '1', unit: '', percent: '', base: '', hst: true }])}>Add a line</button>
      </fieldset>
      <div className="field ad-field"><label className="label" htmlFor="pi-notes">Note on the invoice</label><textarea className="input ad-textarea" id="pi-notes" value={f.notes} onChange={(e) => set('notes')(e.target.value)} /></div>
      <p data-testid="pi-totals">Before HST {money(t.subtotal, { cents: true })} · HST {money(t.hst, { cents: true })} · <b>Total {money(t.total, { cents: true })}</b></p>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <div className="row">
        <button className="btn btn--ghost" type="submit" disabled={pending}>{pending ? 'Saving' : 'Save the draft'}</button>
        <button className="btn btn--primary" type="button" disabled={pending} onClick={() => save(true)} data-testid="pi-send">Save and send to the partner</button>
      </div>
    </form>
  );
}
