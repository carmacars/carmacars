'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { confirmFormUpload, createFormUpload } from '@/server/actions/owner';

// Forms C and D (migration 0040; simpler in 0049): print the pre-filled form (every spot to sign marked), sign it on paper
// with the witnesses, then take a photo with the phone's camera (or choose a PDF scan) and give the witnesses' names.
// Staff review it; a form sent back says what to fix. They stay on paper because they need witnesses in person.
export interface WForm { code: 'C' | 'D1'; vehicle_id: string | null; vehicle_name: string | null; title: string; witnesses: number; status: 'needed' | 'uploaded' | 'approved' | 'rejected'; reject_reason: string | null; uploaded_at: string | null }
const STATUS: Record<WForm['status'], string> = { needed: 'To do', uploaded: 'Waiting for our review', approved: 'Approved', rejected: 'Sent back' };

async function photo(file: File): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  const scale = Math.min(1, 2400 / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
  c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
  return new Promise((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error('Could not read the image'))), 'image/jpeg', 0.9));
}

function One({ f }: { f: WForm }) {
  const id = useId();
  const router = useRouter();
  const [w1, setW1] = useState('');
  const [w2, setW2] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<Record<string, string>>({});
  const [ok, setOk] = useState(false);
  const href = `/owner/documents/witnessed/${f.code === 'C' ? 'C' : 'D'}${f.vehicle_id ? `?vehicle=${f.vehicle_id}` : ''}`;
  const pick = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setErr({}); setBusy(true);
    try {
      const isPdf = file.type === 'application/pdf';
      const body: Blob = isPdf ? file : await photo(file);
      const t = await createFormUpload(f.code, f.vehicle_id, { w1, w2 }, isPdf ? 'application/pdf' : 'image/jpeg', body.size);
      if (!t.ok) { setErr({ ...(t.fieldErrors ?? {}), form: t.fieldErrors ? '' : t.message }); return; }
      const put = await fetch(t.data.url, { method: 'PUT', body, headers: t.data.headers });
      if (!put.ok) throw new Error('The upload did not finish. Try again.');
      const c = await confirmFormUpload(t.data.ticket);
      if (!c.ok) throw new Error(c.message);
      setOk(true); router.refresh();
    } catch (x) { setErr({ form: x instanceof Error ? x.message : 'The upload did not finish. Try again.' }); } finally { setBusy(false); }
  };
  const open = (f.status === 'needed' || f.status === 'rejected') && !ok;
  return (
    <li className="pt-up stack" data-testid={`witnessed-${f.code}${f.vehicle_id ? `-${f.vehicle_id}` : ''}`}>
      <div className="pt-card__head"><h3 className="d4">{f.title}</h3><span className="badge badge--outline">{ok ? STATUS.uploaded : STATUS[f.status]}</span></div>
      {f.vehicle_name && <p className="small">{f.vehicle_name}</p>}
      {f.status === 'rejected' && f.reject_reason && !ok && <p className="alert alert--error" role="alert"><span className="alert__title">What to fix</span><span>{f.reject_reason}</span></p>}
      {open && <>
        <ol className="small">
          <li><a className="link" href={href} target="_blank" rel="noreferrer" data-testid="witnessed-download">Print the form</a>: everything is filled in, and each spot to sign or initial is marked.</li>
          <li>Sign it in front of {f.witnesses === 2 ? 'two adult witnesses' : 'one adult witness'}; they sign and print their names in their spots.</li>
          <li>Type {f.witnesses === 2 ? 'their names' : 'their name'} below, then take a photo of the signed page with your phone.</li>
        </ol>
        <div className="field-row">
          <div className={`field${err.w1 ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-w1`}>{f.witnesses === 2 ? 'First witness' : 'Witness'}, full name</label>
            <input className="input" id={`${id}-w1`} value={w1} onChange={(e) => setW1(e.target.value)} autoComplete="off" aria-invalid={!!err.w1 || undefined} aria-describedby={`${id}-w1-err`} />
            <p className="error" role="alert" id={`${id}-w1-err`}>{err.w1 ?? ''}</p></div>
          {f.witnesses === 2 && <div className={`field${err.w2 ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-w2`}>Second witness, full name</label>
            <input className="input" id={`${id}-w2`} value={w2} onChange={(e) => setW2(e.target.value)} autoComplete="off" aria-invalid={!!err.w2 || undefined} aria-describedby={`${id}-w2-err`} />
            <p className="error" role="alert" id={`${id}-w2-err`}>{err.w2 ?? ''}</p></div>}
        </div>
        <div className="row">
          <label className="btn btn--primary btn--sm" htmlFor={`${id}-cam`}>{busy ? 'Uploading' : 'Take a photo of the signed page'}</label>
          <input id={`${id}-cam`} className="vh" type="file" accept="image/*" capture="environment" onChange={pick} disabled={busy} aria-label={`${f.title}: take a photo of the signed page`} data-testid="witnessed-camera" />
          <label className="btn btn--ghost btn--sm" htmlFor={`${id}-file`}>Or choose a file</label>
          <input id={`${id}-file`} className="vh" type="file" accept="application/pdf,image/jpeg,image/png" onChange={pick} disabled={busy} aria-label={`${f.title}: choose the signed form`} data-testid="witnessed-file" />
        </div>
        {err.form && <p className="error" role="alert">{err.form}</p>}
      </>}
      {ok && <p className="small" role="status">Thanks. We review it within one business day and email you.</p>}
    </li>
  );
}

export function WitnessedForms({ forms }: { forms: WForm[] }) {
  if (!forms.length) return null;
  return <ul className="stack" style={{ listStyle: 'none', padding: 0 }} data-testid="witnessed-forms">{forms.map((f) => <One key={`${f.code}:${f.vehicle_id ?? ''}`} f={f} />)}</ul>;
}
