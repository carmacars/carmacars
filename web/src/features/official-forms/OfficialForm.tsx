'use client';
import { useState } from 'react';
import type { Spec } from './fill';

// The owner's official registry form (migration 0042): the publisher's PDF, unchanged except its empty text boxes,
// filled in this browser from the values on record (0120). It is printed and signed in ink: an official ServiceOntario
// form is never signed on screen, and its checkboxes are ticked by hand at the registry office.
export type Official = { id: string; form_code: string; title: string | null; vehicle_name: string; status: string; missing: string[]; field_values: Record<string, string | null>;
  field_map: Record<string, Spec | string>; signed_document_id: string | null };

export function OfficialForm({ f }: { f: Official }) {
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const signed = f.status === 'signed' || f.status === 'filed';
  const download = async () => {
    setBusy(true); setMsg(null);
    try {
      const r = await fetch(`/owner/documents/forms/${f.id}/template`);
      if (!r.ok) throw new Error('The form could not be opened. Try again.');
      const { fillPdf } = await import('./fill');
      const out = await fillPdf(await r.arrayBuffer(), f.field_values, f.field_map);
      const url = URL.createObjectURL(new Blob([out.bytes as unknown as BlobPart], { type: 'application/pdf' }));
      const a = document.createElement('a'); a.href = url; a.download = `${f.form_code}-${f.vehicle_name.replace(/[^\w]+/g, '-')}.pdf`; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 30_000);
      setMsg({ ok: true, text: out.xfaOnly
        ? 'Downloaded. This form is an Adobe form: open it in Adobe Acrobat Reader (free) to see and print it; other PDF viewers show a blank page, as they do with the form from ServiceOntario.'
        : 'Downloaded. Check every value, then print it.' });
    } catch (e) { setMsg({ ok: false, text: e instanceof Error ? e.message : 'The form could not be made.' }); } finally { setBusy(false); }
  };
  return (
    <div className="stack" data-testid="official-form">
      <section className="pt-card stack" aria-labelledby="of-what"><h2 className="d4" id="of-what">Your form, filled from your records</h2>
        {f.missing.length > 0 && <p className="alert alert--error" role="alert"><span>Still missing: {f.missing.join(', ')}. Ask us to add it before you print it.</span></p>}
        <p className="small">This is the official ServiceOntario form, exactly as ServiceOntario publishes it. Only its empty text boxes are filled in, from your application and your vehicle.</p>
        <p className="small" data-testid="official-ink"><strong>Print it and sign it in ink.</strong> It is not signed on screen. Tick its boxes and sign it by hand, at the registry office or before you go, as we tell you.</p>
        <div className="row"><button type="button" className="btn btn--primary" disabled={busy} onClick={download} data-testid="official-download">{busy ? 'Preparing' : 'Download the filled form'}</button>
          {signed && f.signed_document_id && <a className="btn btn--ghost" href={`/owner/documents/${f.signed_document_id}`} data-testid="official-signed-copy">Open the signed copy</a>}</div>
      </section>
      {signed && <p className="small" data-testid="official-signed">{f.status === 'filed' ? 'Filed at the registry.' : 'Signed. We file it at the registry with you.'}</p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
}
