'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { confirmUpload, createUpload } from '@/server/actions/portal';
import { toStandardImage } from '@/features/uploads/standard-image';
import { PHOTO_ACCEPT } from '@/features/uploads/formats';

// One upload (08-forms.md section 7): camera or file; images are re-encoded in the browser (which strips
// location data) before a short-lived upload link sends them straight to private storage; the server then
// checks the real type and size and registers the upload (register_verification_upload).
export type UploadKind = 'licence_front' | 'licence_back' | 'selfie' | 'coverage_proof';

/** Kept for callers: every photo goes through the standard conversion (formats.ts: JPG, PNG, HEIC, WEBP, a PDF's first page). */
export async function reencode(file: File): Promise<Blob> { return toStandardImage(file); }

const STATE: Record<string, string> = { submitted: 'In review', approved: 'Verified', rejected: 'Needs a new photo' };

export function UploadCard({ number, kind, driverId, title, hint, status, reason, details }: {
  number: string; kind: UploadKind; driverId: string | null; title: string; hint: string; status?: string | null; reason?: string | null;
  details?: Record<string, string> | null;
}) {
  const id = useId();
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState(false);
  const [retake, setRetake] = useState('');
  const pdf = kind === 'coverage_proof';
  const pick = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (!file) return;
    setError(''); setBusy(true);
    try {
      // a PDF stays a PDF for a coverage proof; for a licence or a selfie its first page becomes the photo (formats.ts)
      const isPdf = pdf && (file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf'));
      const body: Blob = isPdf ? file : await toStandardImage(file);
      const type = isPdf ? 'application/pdf' : 'image/jpeg';
      const t = await createUpload(number, kind, driverId, type, body.size);
      if (!t.ok) throw new Error(t.message);
      const put = await fetch(t.data.url, { method: 'PUT', body, headers: t.data.headers });
      if (!put.ok) throw new Error('The upload did not finish. Try again.');
      const c = await confirmUpload(t.data.ticket, details ?? null);
      if (!c.ok) throw new Error(c.message);
      // the licence read on the server straight away (release 31): a photo it cannot use is taken again now
      setRetake(c.data?.retake ?? '');
      setDone(true);
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'The upload did not finish. Try again.');
    } finally {
      setBusy(false);
    }
  };
  const shown = done && status !== 'approved' ? 'submitted' : status;
  return (
    <div className="pt-up" data-testid={`upload-${kind}${driverId ? `-${driverId.slice(0, 8)}` : ''}`}>
      <div className="pt-card__head"><h3 className="d4">{title}</h3>{shown && <span className={`badge ${shown === 'approved' ? '' : shown === 'rejected' ? 'badge--red' : 'badge--outline'}`}>{STATE[shown] ?? shown}</span>}</div>
      <p className="small muted" id={`${id}-hint`}>{hint}</p>
      {shown === 'rejected' && reason && <p className="small" role="note"><b>What to fix:</b> {reason}</p>}
      {/* r32: two choices on a phone: the camera, or a photo or scan already on it (HEIC, WEBP, PDF too); a forced camera
          hides the photo library on an iPhone. A selfie is the camera only. */}
      <label className={`btn ${shown ? 'btn--ghost' : 'btn--primary'} btn--sm`} htmlFor={`${id}-file`}>{busy ? 'Uploading' : kind === 'selfie' ? (shown ? 'Retake selfie' : 'Take selfie') : shown ? 'Replace: take a photo' : 'Take a photo'}</label>
      <input id={`${id}-file`} type="file" accept={kind === 'selfie' ? 'image/*' : PHOTO_ACCEPT} capture={kind === 'selfie' ? 'user' : 'environment'}
        onChange={pick} disabled={busy} aria-describedby={`${id}-hint ${id}-err`} aria-label={`${title}: take a photo`} data-testid={`upload-camera-${kind}`} />
      {kind !== 'selfie' && <><label className="btn btn--quiet btn--sm" htmlFor={`${id}-pick`}>Choose from my photos</label>
        <input id={`${id}-pick`} type="file" accept={PHOTO_ACCEPT} onChange={pick} disabled={busy} aria-describedby={`${id}-hint ${id}-err`} aria-label={`${title}: choose from my photos${pdf ? ' or a PDF' : ''}`} data-testid={`upload-pick-${kind}`} /></>}
      {retake && <p className="alert alert--warn" role="alert" data-testid={`retake-${kind}`}><span>{retake}</span></p>}
      <p className="error" role="alert" id={`${id}-err`}>{error}</p>
    </div>
  );
}
