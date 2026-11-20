'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { feeEvidenceUpload } from '@/server/actions/fee-evidence';

// r48 FE (3190): attach a receipt, an invoice, a notice or a photo (or a note) to one fee line. The database checks the
// evidence again; the fee is charged once nothing is missing.
const KINDS: Array<[string, string]> = [['receipt', 'Receipt'], ['invoice', 'Invoice'], ['photo', 'Photo'], ['notice', 'Notice (ticket, 407)'], ['police_report', 'Police report'], ['damage_closeup', 'Damage close-up'], ['other', 'Other']];

export function EvidenceUpload({ bookingId, lineId, testId }: { bookingId: string; lineId: string; testId?: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState('receipt');
  const [file, setFile] = useState<File | null>(null);
  const [note, setNote] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const send = () => run(async () => {
    setMsg(null);
    const form = new FormData();
    form.set('booking', bookingId); form.set('line', lineId); form.set('kind', kind); form.set('note', note);
    if (file) form.set('file', file);
    const r = await feeEvidenceUpload(form);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: r.data.evidence_status === 'ok' ? 'Attached: the evidence is complete.' : 'Attached. Something is still missing (see the line).' });
    setFile(null); setNote(''); setOpen(false);
    router.refresh();
  });
  if (!open) return <><button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid={testId}>Attach evidence</button>{msg && <span className={`small ${msg.ok ? '' : 'error'}`} role="status">{msg.text}</span>}</>;
  return (
    <div className="stack" data-testid={testId ? `${testId}-form` : undefined}>
      <label className="field"><span className="label">What it is</span>
        <select className="select" value={kind} onChange={(e) => setKind(e.target.value)}>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
      <label className="field"><span className="label">The file (photo or PDF, under 15 MB)</span>
        <input className="input" type="file" accept="image/jpeg,image/png,application/pdf" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></label>
      <label className="field"><span className="label">A note or description (the renter may see it)</span>
        <textarea className="input" value={note} onChange={(e) => setNote(e.target.value)} placeholder="What it shows: where, when, how bad" /></label>
      <p className="ad-actions"><button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={send}>{pending ? 'Sending' : 'Attach'}</button>
        <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(false)}>Cancel</button></p>
      {msg && <p className={msg.ok ? 'small' : 'error'} role="alert">{msg.text}</p>}
    </div>
  );
}
