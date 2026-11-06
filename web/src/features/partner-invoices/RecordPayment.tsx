'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDo } from '@/server/actions/staff-tools';
import { DateInput } from '@/components/DateInput';
import { toStandardImage } from '@/features/uploads/standard-image';
import { METHODS } from './model';

// Money a partner sent for an invoice (migration 0547): how, how much, when, the cheque number or e-Transfer
// reference, and a photo of the cheque if wanted (made a smaller JPEG on the device, kept in private storage).
export function RecordPayment({ id, balanceCents, refresh }: { id: string; balanceCents: number; refresh: string[] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [f, setF] = useState({ method: 'cheque', amount: (balanceCents / 100).toFixed(2), received_on: '', reference: '', note: '' });
  const [photo, setPhoto] = useState<File | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (k: keyof typeof f) => (v: string) => setF((s) => ({ ...s, [k]: v }));
  const save = () => start(async () => {
    setMsg(null);
    const cents = Math.round(Number(f.amount.replace(/[$,\s]/g, '')) * 100);
    if (!Number.isFinite(cents) || cents <= 0) { setMsg({ ok: false, text: 'Enter the amount received.' }); return; }
    let photo_path: string | null = null;
    if (photo) {
      const fd = new FormData();
      fd.append('id', id);
      fd.append('file', await toStandardImage(photo), 'cheque.jpg');
      const r = await fetch('/api/staff/partner-invoice', { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({}))) as { ok?: boolean; path?: string; message?: string };
      if (!j.ok || !j.path) { setMsg({ ok: false, text: j.message ?? 'The cheque photo could not be uploaded.' }); return; }
      photo_path = j.path;
    }
    const r = await staffDo('partner_invoice_pay', { id, method: f.method, amount_cents: cents, received_on: f.received_on || null, reference: f.reference, note: f.note, photo_path }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: 'Recorded.' });
    setOpen(false); setPhoto(null);
    router.refresh();
  });
  if (!open) return (<>
    <button className="btn btn--primary btn--sm" type="button" onClick={() => setOpen(true)} data-testid="pi-pay">Record money received</button>
    {msg?.ok && <span className="small" role="status">{msg.text}</span>}
  </>);
  return (
    <form className="stack ad-form" data-testid="pi-pay-form" onSubmit={(e) => { e.preventDefault(); save(); }}>
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="pi-pay-m">How</label>
          <select className="select" id="pi-pay-m" value={f.method} onChange={(e) => set('method')(e.target.value)}>{METHODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-pay-a">Amount ($)</label><input className="input" id="pi-pay-a" inputMode="decimal" required value={f.amount} onChange={(e) => set('amount')(e.target.value)} data-testid="pi-pay-amount" /></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-pay-d">Received on (empty: today)</label><DateInput className="input" id="pi-pay-d" type="date" value={f.received_on} onChange={(e) => set('received_on')(e.target.value)} /></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-pay-r">Cheque number or e-Transfer reference</label><input className="input" id="pi-pay-r" value={f.reference} onChange={(e) => set('reference')(e.target.value)} /></div>
        <div className="field ad-field"><label className="label" htmlFor="pi-pay-p">Photo of the cheque (optional)</label><input className="input" id="pi-pay-p" type="file" accept="image/*" onChange={(e) => setPhoto(e.target.files?.[0] ?? null)} data-testid="pi-pay-photo" /></div>
        <div className="field ad-field ad-field--wide"><label className="label" htmlFor="pi-pay-n">Note</label><input className="input" id="pi-pay-n" value={f.note} onChange={(e) => set('note')(e.target.value)} /></div>
      </div>
      {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
      <div className="row">
        <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="pi-pay-submit">{pending ? 'Saving' : 'Record'}</button>
        <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button>
      </div>
    </form>
  );
}
