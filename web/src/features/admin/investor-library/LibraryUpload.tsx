'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { investorLibrarySave } from '@/server/actions/investor-library';

// Admin > Investors > Documents (r50, migration 4300): add a document (a section, a title, a PDF or a deck link), or, with
// `item`, upload its new version. Investors are told by email and in their portal.
export function LibraryUpload({ kinds, item, title, testId }: { kinds?: Array<{ key: string; label: string }>; item?: string; title?: string; testId: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(!item);
  const [kind, setKind] = useState(kinds?.[0]?.key ?? '');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const send = (form: FormData) => run(async () => {
    setMsg(null);
    if (item) form.set('item', item);
    const r = await investorLibrarySave(form);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: `Saved as version ${r.data.version}. ${r.data.told === 1 ? 'One investor was' : `${r.data.told} investors were`} told.` });
    if (item) setOpen(false);
    router.refresh();
  });
  if (!open) return <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}><button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid={testId}>Replace</button>{msg && <span className={`small ${msg.ok ? '' : 'error'}`} role="status">{msg.text}</span>}</span>;
  return (
    <form className="stack" data-testid={`${testId}-form`} action={send}>
      {!item && <div className="ad-grid ad-grid--2">
        <label className="field"><span className="label">Section</span>
          <select className="select" name="kind" value={kind} onChange={(e) => setKind(e.target.value)} data-testid={`${testId}-kind`}>
            {(kinds ?? []).map((k) => <option key={k.key} value={k.key}>{k.label}</option>)}<option value="_new">A new section</option></select></label>
        {kind === '_new' && <label className="field"><span className="label">New section name</span><input className="input" name="kind_label" maxLength={60} placeholder="For example: Market research" data-testid={`${testId}-kind-label`} /></label>}
      </div>}
      <label className="field"><span className="label">Title{item ? ' (leave as is, or change it)' : ''}</span>
        <input className="input" name="title" defaultValue={title} maxLength={120} required={!item} minLength={3} data-testid={`${testId}-title`} /></label>
      <div className="ad-grid ad-grid--2">
        <label className="field"><span className="label">The file (PDF, under 50 MB)</span>
          <input className="input" type="file" name="file" accept="application/pdf" data-testid={`${testId}-file`} /></label>
        <label className="field"><span className="label">Or a link to the deck (https)</span>
          <input className="input" type="url" name="link_url" placeholder="https://" maxLength={500} data-testid={`${testId}-link`} /></label>
      </div>
      <label className="field"><span className="label">What changed (Admins only, optional)</span><input className="input" name="note" maxLength={500} /></label>
      <p className="ad-actions"><button type="submit" className="btn btn--primary btn--sm" disabled={pending} data-testid={`${testId}-save`}>{pending ? 'Saving' : item ? 'Save the new version' : 'Add the document'}</button>
        {item && <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(false)}>Cancel</button>}</p>
      {msg && <p className={msg.ok ? 'small' : 'error'} role={msg.ok ? 'status' : 'alert'} data-testid={`${testId}-msg`}>{msg.text}</p>}
    </form>
  );
}
