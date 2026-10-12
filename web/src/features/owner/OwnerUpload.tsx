'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { confirmOwnerUpload, createOwnerUpload } from '@/server/actions/owner';

// A vehicle document from a phone camera or a file: photos are re-encoded in the browser (which strips
// location data), sent straight to private storage with a short-lived link, then checked and recorded.
async function reencode(file: File): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  const scale = Math.min(1, 2400 / Math.max(bmp.width, bmp.height));
  const c = document.createElement('canvas');
  c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale);
  c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height);
  return new Promise((res, rej) => c.toBlob((b) => (b ? res(b) : rej(new Error('Could not read the image'))), 'image/jpeg', 0.9));
}

export function OwnerUpload({ vehicleId, kind, title, hint, done }: { vehicleId: string; kind: 'ownership_permit' | 'finance_party_permission' | 'owner_insurance_proof'; title: string; hint: string; done: boolean }) {
  const id = useId();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [sent, setSent] = useState(0);
  const pick = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = [...(e.target.files ?? [])];
    e.target.value = '';
    if (!files.length) return;
    setError(''); setBusy(true);
    try {
      for (const file of files.slice(0, 4)) {
        const isPdf = file.type === 'application/pdf';
        const body: Blob = isPdf ? file : await reencode(file);
        const t = await createOwnerUpload(vehicleId, kind, isPdf ? 'application/pdf' : 'image/jpeg', body.size);
        if (!t.ok) throw new Error(t.message);
        const put = await fetch(t.data.url, { method: 'PUT', body, headers: t.data.headers });
        if (!put.ok) throw new Error('The upload did not finish. Try again.');
        const c = await confirmOwnerUpload(t.data.ticket);
        if (!c.ok) throw new Error(c.message);
        setSent((n) => n + 1);
      }
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'The upload did not finish. Try again.');
    } finally { setBusy(false); }
  };
  const have = done || sent > 0;
  return (
    <div className="pt-up" data-testid={`owner-upload-${kind}`}>
      <div className="pt-card__head"><h3 className="d4">{title}</h3>{have && <span className="badge badge--outline">Received</span>}</div>
      <p className="small muted" id={`${id}-hint`}>{hint}</p>
      <label className={`btn ${have ? 'btn--ghost' : 'btn--primary'} btn--sm`} htmlFor={`${id}-file`}>{busy ? 'Uploading' : have ? 'Add another page' : 'Take photos or choose files'}</label>
      <input id={`${id}-file`} type="file" multiple accept="image/jpeg,image/png,application/pdf" onChange={pick} disabled={busy} aria-describedby={`${id}-hint ${id}-err`} aria-label={`${title}: choose photos or a PDF`} />
      <p className="error" role="alert" id={`${id}-err`}>{error}</p>
    </div>
  );
}
