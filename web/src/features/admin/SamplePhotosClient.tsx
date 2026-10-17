'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { photoUrl } from '@/lib/photo';
import { deleteSamplePhoto, saveAdminAccess, setSamplePhotoActive, uploadSamplePhoto } from '@/server/actions/samples-access';

// Admin > Settings > Sample photos (migration 0054): add a stock photo for a make and model, a make, or a body type;
// turn one off or delete it. Admin access: the addresses that may hold the Admin role.
const BODY: Array<[string, string]> = [['', 'Any body type'], ['sedan', 'Sedan'], ['suv', 'SUV'], ['truck', 'Pickup truck'], ['van', 'Van'], ['coupe', 'Coupe'], ['hatchback', 'Hatchback'], ['ev', 'Electric car']];

export function SampleUpload() {
  const router = useRouter();
  const uid = `su-${useId().replace(/[^\w-]/g, '')}`;
  const [pending, start] = useTransition();
  const [err, setErr] = useState<Record<string, string>>({});
  const [ok, setOk] = useState(false);
  return (
    <form className="stack" noValidate aria-label="Add a sample photo" data-testid="sample-upload" onSubmit={(e) => {
      e.preventDefault(); const fd = new FormData(e.currentTarget); const form = e.currentTarget;
      start(async () => { const r = await uploadSamplePhoto(fd); if (!r.ok) { setErr({ ...(r.fieldErrors ?? {}), form: r.fieldErrors ? '' : r.message }); setOk(false); return; } setErr({}); setOk(true); form.reset(); router.refresh(); });
    }}>
      <div className="ad-fields">
        <div className={`field ad-field${err.body_type ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-b`}>Body type</label>
          <select className="input" id={`${uid}-b`} name="body_type">{BODY.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select><p className="error" role="alert">{err.body_type ?? ''}</p></div>
        <div className={`field ad-field${err.make ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-m`}>Make (optional)</label><input className="input" id={`${uid}-m`} name="make" placeholder="Toyota" /><p className="error" role="alert">{err.make ?? ''}</p></div>
        <div className="field ad-field"><label className="label" htmlFor={`${uid}-o`}>Model (optional)</label><input className="input" id={`${uid}-o`} name="model" placeholder="RAV4" /></div>
        <div className="field ad-field"><label className="label" htmlFor={`${uid}-a`}>Description for screen readers (optional)</label><input className="input" id={`${uid}-a`} name="alt" placeholder="A white Toyota RAV4, front three-quarter view" /></div>
        <div className={`field ad-field${err.file ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-f`}>Photo (JPEG or WebP, landscape)</label><input className="input" id={`${uid}-f`} name="file" type="file" accept="image/jpeg,image/webp" data-testid="sample-file" /><p className="error" role="alert">{err.file ?? ''}</p></div>
      </div>
      <p className="small muted">The most specific photo wins: make and model, then make and body type, then body type. A car with none of these shows the built-in picture of its body type.</p>
      <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="sample-add">{pending ? 'Uploading' : 'Add the photo'}</button>
        {ok && <span className="small" role="status">Added. Cars that match now show it.</span>}</div>
      {err.form && <p className="alert alert--error" role="alert"><span>{err.form}</span></p>}
    </form>
  );
}

export function SampleRowActions({ id, active }: { id: string; active: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <span className="row" style={{ gap: 'var(--s-2)' }}>
      <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => start(async () => { await setSamplePhotoActive(id, !active); router.refresh(); })}>{active ? 'Turn off' : 'Turn on'}</button>
      <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => { if (window.confirm('Delete this sample photo?')) start(async () => { await deleteSamplePhoto(id); router.refresh(); }); }}>Delete</button>
    </span>
  );
}

export function SampleThumb({ path, alt }: { path: string; alt: string }) {
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={photoUrl(path)} alt={alt} width={120} height={80} style={{ objectFit: 'cover', width: 120, height: 80, background: 'var(--grey-100)' }} loading="lazy" />;
}

export function AdminAccessForm({ allowed }: { allowed: string[] }) {
  const router = useRouter();
  const uid = `aa-${useId().replace(/[^\w-]/g, '')}`;
  const [text, setText] = useState(allowed.join('\n'));
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (
    <form className="stack" noValidate aria-label="Admin access" data-testid="admin-access-form" onSubmit={(e) => { e.preventDefault(); start(async () => { const r = await saveAdminAccess(text); setMsg(r.ok ? { ok: true, text: 'Saved.' } : { ok: false, text: r.message }); if (r.ok) router.refresh(); }); }}>
      <div className="field"><label className="label" htmlFor={`${uid}-e`}>Addresses that may be an Admin (one per line)</label>
        <textarea className="input" id={`${uid}-e`} rows={3} value={text} onChange={(e) => setText(e.target.value)} data-testid="admin-access-emails" /></div>
      <div className="row"><button className="btn btn--ghost btn--sm" type="submit" disabled={pending}>{pending ? 'Saving' : 'Save'}</button>{msg && <span className={msg.ok ? 'small' : 'ad-err'} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}</div>
    </form>
  );
}
