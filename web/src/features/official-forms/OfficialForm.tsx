'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { SignaturePad } from '@/features/portal/SignaturePad';
import type { Spec } from './fill';
import { ownerSigns } from './signs';

// The owner's official registry form (migration 0042), filled in this browser from the values on record: download
// it as it is, or sign it on screen and save the signed copy with your documents.
export type Official = { id: string; form_code: string; title: string | null; vehicle_name: string; status: string; missing: string[]; field_values: Record<string, string | null>;
  field_map: Record<string, Spec | string>; signed_document_id: string | null };
const b64 = (s: string) => Uint8Array.from(atob(s.replace(/^data:image\/png;base64,/, '')), (c) => c.charCodeAt(0));

export function OfficialForm({ f }: { f: Official }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [sig, setSig] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const hasSignature = ownerSigns(f.field_values, f.field_map);
  const signed = f.status === 'signed' || f.status === 'filed';
  const make = async (signature?: string) => {
    const r = await fetch(`/owner/documents/forms/${f.id}/template`);
    if (!r.ok) throw new Error('The form could not be opened. Try again.');
    const { fillPdf } = await import('./fill');
    return fillPdf(await r.arrayBuffer(), f.field_values, f.field_map, signature ? { signaturePng: b64(signature), flatten: true } : {});
  };
  const download = async () => {
    setBusy(true); setMsg(null);
    try {
      const out = await make();
      const url = URL.createObjectURL(new Blob([out.bytes as unknown as BlobPart], { type: 'application/pdf' }));
      const a = document.createElement('a'); a.href = url; a.download = `${f.form_code}-${f.vehicle_name.replace(/[^\w]+/g, '-')}.pdf`; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 30_000);
      setMsg({ ok: true, text: 'Downloaded. Check every value before you sign it.' });
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The form could not be made.' }); } finally { setBusy(false); }
  };
  const sign = async () => {
    if (!sig) return;
    setBusy(true); setMsg(null);
    try {
      const out = await make(sig);
      const r = await fetch(`/owner/documents/forms/${f.id}/signed`, { method: 'POST', headers: { 'content-type': 'application/pdf' }, body: out.bytes as unknown as BodyInit });
      const j = (await r.json().catch(() => ({ ok: false, message: 'The server did not answer.' }))) as { ok: boolean; message?: string };
      if (!j.ok) throw new Error(j.message ?? 'The signed form could not be saved.');
      setMsg({ ok: true, text: 'Signed and saved with your documents.' });
      router.refresh();
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The signed form could not be saved.' }); } finally { setBusy(false); }
  };
  return (
    <div className="stack" data-testid="official-form">
      <section className="pt-card stack" aria-labelledby="of-what"><h2 className="d4" id="of-what">Your form, filled from your records</h2>
        {f.missing.length > 0 && <p className="alert alert--error" role="alert"><span>Still missing: {f.missing.join(', ')}. Ask us to add it before you sign.</span></p>}
        <p className="small">Every value comes from your application and your vehicle. Download it and check each one. If the registry office asks for an ink signature, print it and sign it there.</p>
        <div className="row"><button type="button" className="btn btn--primary" disabled={busy} onClick={download} data-testid="official-download">{busy ? 'Preparing' : 'Download the filled form'}</button>
          {signed && f.signed_document_id && <a className="btn btn--ghost" href={`/owner/documents/${f.signed_document_id}`} data-testid="official-signed-copy">Open the signed copy</a>}</div>
      </section>
      {hasSignature && !signed && f.status !== 'draft' && <section className="pt-card stack" aria-labelledby="of-sign"><h2 className="d4" id="of-sign">Sign on screen</h2>
        <p className="small muted">Draw your signature with a finger, a pen or the mouse. It is placed in the signature box of the form, and the signed copy is kept with your documents.</p>
        <SignaturePad id={`of-pad-${f.id}`} onChange={setSig} />
        <button type="button" className="btn btn--primary" disabled={busy || !sig} onClick={sign} data-testid="official-sign">{busy ? 'Saving' : 'Sign and save'}</button>
      </section>}
      {signed && <p className="small" data-testid="official-signed">Signed. We file it at the registry with you.</p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
