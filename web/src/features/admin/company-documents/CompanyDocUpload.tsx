'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { companyDocumentSave } from '@/server/actions/company-documents';
import type { CompanyDocAdmin } from '@/features/company-documents/model';

// Admin > Company documents (r50, migration 5060): add a document (a kind, a title, notes, then a PDF or a text to sign with
// its signers), or, with `document`, its next version (a text starts with the signers of the version before). A text to sign goes to its page for the fill-ins.
export function CompanyDocUpload({ kinds, admins, document, title, signable, signers: initial = [], testId }: {
  kinds?: Array<{ key: string; label: string }>; admins: CompanyDocAdmin[]; document?: string; title?: string; signable?: boolean;
  /** a new version starts with the signers of the one before */ signers?: Array<{ user_id: string; role_label: string }>; testId: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(!document);
  const [mode, setMode] = useState<'pdf' | 'text'>(signable ? 'text' : 'pdf');
  const [signers, setSigners] = useState<Array<{ user_id: string; role_label: string }>>(initial);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const toggle = (id: string, on: boolean) => setSigners((x) => (on ? [...x, { user_id: id, role_label: '' }] : x.filter((s) => s.user_id !== id)));
  const send = (form: FormData) => run(async () => {
    setMsg(null);
    if (document) form.set('document', document);
    form.set('mode', mode);
    form.set('signers', JSON.stringify(signers.map((s) => ({ user_id: s.user_id, role_label: s.role_label.trim() || 'Signer' }))));
    const r = await companyDocumentSave(form);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    if (r.data.file_kind === 'signable') { router.push(`/admin/company-documents/${r.data.document}`); return; }
    setMsg({ ok: true, text: `Saved as version ${r.data.version}.` });
    if (document) setOpen(false);
    router.refresh();
  });
  if (!open) return <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid={testId}>New version</button>;
  return (
    <form className="stack" data-testid={`${testId}-form`} action={send}>
      {!document && <div className="ad-grid ad-grid--2">
        <label className="field"><span className="label">Kind</span>
          <select className="select" name="kind" defaultValue={kinds?.[0]?.key} data-testid={`${testId}-kind`}>{(kinds ?? []).map((k) => <option key={k.key} value={k.key}>{k.label}</option>)}</select></label>
        <label className="field"><span className="label">Title</span><input className="input" name="title" defaultValue={title} maxLength={120} minLength={3} required data-testid={`${testId}-title`} /></label>
      </div>}
      <fieldset className="stack"><legend className="label">What it is</legend>
        <span className="row" style={{ gap: 'var(--s-3)', flexWrap: 'wrap' }}>
          <label className="check"><input type="radio" name="mode_pick" checked={mode === 'pdf'} onChange={() => setMode('pdf')} data-testid={`${testId}-mode-pdf`} /><span>A PDF to keep</span></label>
          <label className="check"><input type="radio" name="mode_pick" checked={mode === 'text'} onChange={() => setMode('text')} data-testid={`${testId}-mode-text`} /><span>A text to sign in Admin</span></label>
        </span></fieldset>
      {mode === 'pdf' ? (
        <label className="field"><span className="label">The file (PDF, under 20 MB)</span>
          <input className="input" type="file" name="file" accept="application/pdf" data-testid={`${testId}-file`} /></label>
      ) : (<>
        <label className="field"><span className="label">The text (Markdown; write fill-ins as {'{{name}}'}, for example {'{{holdco_a}}'})</span>
          <textarea className="textarea" name="body_md" rows={10} maxLength={200000} data-testid={`${testId}-body`} /></label>
        <fieldset className="stack" data-testid={`${testId}-signers`}><legend className="label">Who signs it (Admins only)</legend>
          {admins.map((a) => {
            const s = signers.find((x) => x.user_id === a.id);
            return (
              <div key={a.id} className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'center' }}>
                <label className="check"><input type="checkbox" checked={!!s} onChange={(e) => toggle(a.id, e.target.checked)} data-testid={`${testId}-signer`} /><span>{a.name}</span></label>
                {s && <input className="input" aria-label={`${a.name}'s role`} placeholder="Role, for example: Principal of Side A, and for Holdco A" maxLength={160} value={s.role_label}
                  onChange={(e) => setSigners((x) => x.map((y) => (y.user_id === a.id ? { ...y, role_label: e.target.value } : y)))} data-testid={`${testId}-role`} />}
              </div>
            );
          })}
        </fieldset>
      </>)}
      {!document && <label className="field"><span className="label">Notes (optional)</span><input className="input" name="notes" maxLength={2000} /></label>}
      {document && <label className="field"><span className="label">What changed (optional)</span><input className="input" name="note" maxLength={500} /></label>}
      <p className="ad-actions"><button type="submit" className="btn btn--primary btn--sm" disabled={pending} aria-busy={pending || undefined} data-testid={`${testId}-save`}>{pending ? 'Saving' : document ? 'Save the new version' : 'Add the document'}</button>
        {document && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(false)}>Cancel</button>}</p>
      {msg && <p className={msg.ok ? 'small' : 'error'} role={msg.ok ? 'status' : 'alert'} data-testid={`${testId}-msg`}>{msg.text}</p>}
    </form>
  );
}
