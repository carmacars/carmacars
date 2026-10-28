'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { staffDocumentUpload, staffLicenceUpload } from '@/server/actions/sign-now';

// Staff upload a renter's documents from the booking (migration 0183): the licence (front or back, per driver), the
// insurance policy or pink card, an insurer's authorization or claim letter, or any other document. Photos or PDFs.
type Kind = 'licence_front' | 'licence_back' | 'coverage_proof' | 'insurer_document' | 'other';
const KINDS: Array<[Kind, string]> = [['coverage_proof', 'Insurance policy or pink card'], ['licence_front', 'Licence, front'], ['licence_back', 'Licence, back'],
  ['insurer_document', 'Insurer letter (authorization, claim)'], ['other', 'Other document']];

export function StaffDocUpload({ bookingId, drivers }: { bookingId: string; drivers: Array<{ driver_id: string; full_name: string }> }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [kind, setKind] = useState<Kind>('coverage_proof');
  const [driver, setDriver] = useState(drivers[0]?.driver_id ?? '');
  const [file, setFile] = useState<File | null>(null);
  const [f, setF] = useState({ insurer_name: '', policy_number: '', policy_expiry: '', title: '' });
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const licence = kind === 'licence_front' || kind === 'licence_back';
  const upload = () => run(async () => {
    setMsg(null);
    if (!file) { setMsg({ ok: false, text: 'Choose the file first.' }); return; }
    const form = new FormData();
    form.set('booking', bookingId); form.set('kind', kind); form.set('file', file);
    let r;
    if (licence) {
      if (!driver) { setMsg({ ok: false, text: 'Choose the driver.' }); return; }
      if (file.type === 'application/pdf') { setMsg({ ok: false, text: 'A licence is a photo (JPG or PNG).' }); return; }
      form.set('driver', driver);
      r = await staffLicenceUpload(form);
    } else {
      for (const [k, v] of Object.entries(f)) if (v.trim()) form.set(k, v.trim());
      r = await staffDocumentUpload(form);
    }
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: 'Uploaded. It is on the booking; review it with Review documents.' });
    setFile(null); setF({ insurer_name: '', policy_number: '', policy_expiry: '', title: '' }); router.refresh();
  });
  if (!open) return <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid="sdu-open">Upload a document</button>;
  return (
    <div className="stack" data-testid="staff-doc-upload">
      <div className="ad-fields">
        <div className="field ad-field"><label className="label" htmlFor="sdu-kind">Document</label>
          <select className="input" id="sdu-kind" value={kind} onChange={(e) => setKind(e.target.value as Kind)} data-testid="sdu-kind">
            {KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
        {licence && <div className="field ad-field"><label className="label" htmlFor="sdu-driver">Driver</label>
          <select className="input" id="sdu-driver" value={driver} onChange={(e) => setDriver(e.target.value)} data-testid="sdu-driver">
            {drivers.map((d) => <option key={d.driver_id} value={d.driver_id}>{d.full_name}</option>)}</select></div>}
        {kind === 'coverage_proof' && <>
          <div className="field ad-field"><label className="label" htmlFor="sdu-ins">Insurer (optional)</label>
            <input className="input" id="sdu-ins" value={f.insurer_name} onChange={(e) => setF((s) => ({ ...s, insurer_name: e.target.value }))} /></div>
          <div className="field ad-field"><label className="label" htmlFor="sdu-pol">Policy number (optional)</label>
            <input className="input" id="sdu-pol" value={f.policy_number} onChange={(e) => setF((s) => ({ ...s, policy_number: e.target.value }))} /></div>
          <div className="field ad-field"><label className="label" htmlFor="sdu-exp">Policy expiry (optional)</label>
            <input className="input" id="sdu-exp" type="date" value={f.policy_expiry} onChange={(e) => setF((s) => ({ ...s, policy_expiry: e.target.value }))} /></div></>}
        {(kind === 'insurer_document' || kind === 'other') && <div className="field ad-field"><label className="label" htmlFor="sdu-title">Name (optional)</label>
          <input className="input" id="sdu-title" value={f.title} onChange={(e) => setF((s) => ({ ...s, title: e.target.value }))} /></div>}
        <div className="field ad-field"><label className="label" htmlFor="sdu-file">File (photo or PDF, up to 15 MB)</label>
          <input className="input" id="sdu-file" type="file" accept={licence ? 'image/jpeg,image/png' : 'image/jpeg,image/png,application/pdf'} capture={licence ? 'environment' : undefined}
            onChange={(e) => setFile(e.target.files?.[0] ?? null)} data-testid="sdu-file" /></div>
      </div>
      <div className="row"><button className="btn btn--sm" type="button" disabled={pending} onClick={upload} data-testid="sdu-save">{pending ? 'Uploading…' : 'Upload'}</button>
        <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setOpen(false); setMsg(null); }}>Close</button></div>
      {msg && <p className={`small${msg.ok ? '' : ' form-error'}`} role="status" data-testid="sdu-msg">{msg.text}</p>}
    </div>
  );
}
