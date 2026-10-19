'use client';
import { useId, useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { applicationApprove, applicationCheck, applicationDecline, applicationNote, applicationRequest } from '@/server/actions/applications';
import { CHECKS, CHECK_RESULT } from './applications';

// The owner application page's actions (migration 0054): Approve, Ask for something, Decline; the four checks; notes.
export function ApplicationDecision({ id, status, items, owner, isTest, approve, setup }: { id: string; status: string; items: Array<{ code: string; label: string }>; owner: string; isTest: boolean; approve?: ReactNode; setup?: ReactNode }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  const uid = `ad-${useId().replace(/[^\w-]/g, '')}`;
  const [mode, setMode] = useState<'' | 'ask' | 'decline' | 'approve'>('');
  const [picked, setPicked] = useState<string[]>([]);
  const [message, setMessage] = useState('');
  const [reason, setReason] = useState('');
  const done = (r: { ok: boolean }) => { if (r.ok) { setMode(''); router.refresh(); } };
  if (status === 'approved') return <div className="stack"><p className="small" data-testid="app-approved">Approved. The owner signs the documents and pays the invoices you sent in the owner portal; their progress is on the owner record.</p>{setup}</div>;
  if (status === 'declined') return <p className="small">Declined. Nothing else to do.</p>;
  return (
    <div className="stack">
      <p className="small muted">Approve when the checks are done: you confirm each car&apos;s terms and choose its first invoices (send now, save as a draft, or record as already paid). Then {owner}&apos;s account becomes active, the documents open for one signature in the owner portal, and the owner is emailed{isTest ? ' (a test owner: the staff emails stay with the test accounts)' : ''}.</p>
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
        <button type="button" className="btn btn--primary" disabled={a.pending} data-testid="app-approve" aria-expanded={mode === 'approve'}
          onClick={() => { if (approve) setMode(mode === 'approve' ? '' : 'approve'); else if (window.confirm(`Approve ${owner}? No invoice is made.`)) a.run(() => applicationApprove(id), done); }}>{a.pending ? 'Working' : 'Approve'}</button>
        <button type="button" className="btn btn--ghost" aria-expanded={mode === 'ask'} onClick={() => setMode(mode === 'ask' ? '' : 'ask')} data-testid="app-ask-open">Ask for something</button>
        <button type="button" className="btn btn--quiet" aria-expanded={mode === 'decline'} onClick={() => setMode(mode === 'decline' ? '' : 'decline')} data-testid="app-decline-open">Decline</button>
      </div>
      {mode === 'approve' && approve}
      {mode === 'ask' && (
        <form className="stack pt-sheet" noValidate aria-label="Ask the owner for something" onSubmit={(e) => { e.preventDefault(); a.run(() => applicationRequest(id, picked, message), done); }}>
          <fieldset className={`field${a.err('items') ? ' has-error' : ''}`}><legend className="label">What do you need?</legend>
            {items.map((i) => <label key={i.code} className="check"><input type="checkbox" checked={picked.includes(i.code)} onChange={(e) => setPicked(e.target.checked ? [...picked, i.code] : picked.filter((x) => x !== i.code))} data-testid={`app-item-${i.code}`} /><span>{i.label}</span></label>)}
            <p className="error" role="alert">{a.err('items') ?? ''}</p></fieldset>
          <div className="field"><label className="label" htmlFor={`${uid}-m`}>Message to the owner (optional)</label><textarea className="input" id={`${uid}-m`} rows={3} value={message} onChange={(e) => setMessage(e.target.value)} data-testid="app-ask-message" /></div>
          <p className="small muted">The owner gets an email and a task in their owner portal. The application waits on the owner until they answer.</p>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="app-ask-send">Send to the owner</button></div>
        </form>)}
      {mode === 'decline' && (
        <form className="stack pt-sheet" noValidate aria-label="Decline the application" onSubmit={(e) => { e.preventDefault(); a.run(() => applicationDecline(id, reason), done); }}>
          <div className={`field${a.err('reason') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-r`}>Reason the owner reads</label>
            <textarea className="input" id={`${uid}-r`} rows={3} value={reason} onChange={(e) => setReason(e.target.value)} aria-invalid={!!a.err('reason') || undefined} data-testid="app-decline-reason" />
            <p className="error" role="alert">{a.err('reason') ?? ''}</p></div>
          <p className="small muted">The owner is emailed for each car, with this reason.</p>
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={a.pending} data-testid="app-decline-send">Decline the application</button></div>
        </form>)}
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
    </div>
  );
}

export function ApplicationChecks({ id, checks, disabled }: { id: string; checks: Record<string, { status: string; note: string | null; at: string }>; disabled: boolean }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  return (
    <ul className="ad-list" data-testid="app-check-list">{CHECKS.map(([code, name]) => {
      const c = checks[code];
      return (
        <li key={code}><span><b>{name}</b>{c?.note ? <span className="ad-sub">{c.note}</span> : null}</span>
          <label className="vh" htmlFor={`chk-${code}`}>{name}</label>
          <select id={`chk-${code}`} className="input input--sm" value={c?.status ?? 'not_checked'} disabled={disabled || a.pending} data-testid={`app-check-${code}`}
            onChange={(e) => { const s = e.target.value; const note = s === 'problem' ? (window.prompt(`${name}: what is the problem?`) ?? '') : ''; a.run(() => applicationCheck(id, code, s, note), () => router.refresh()); }}>
            {Object.entries(CHECK_RESULT).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
          </select></li>);
    })}
      {a.res && !a.res.ok && <li><p className="alert alert--error" role="alert"><span>{a.res.message}</span></p></li>}</ul>
  );
}

export function ApplicationNotes({ id, notes }: { id: string; notes: Array<{ id: string; kind: string; body: string; at: string; by: string | null }> }) {
  const router = useRouter();
  const a = useAct<Record<string, unknown>>();
  const uid = `an-${useId().replace(/[^\w-]/g, '')}`;
  const [body, setBody] = useState('');
  const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
  const KIND: Record<string, string> = { note: 'Note', request: 'Asked the owner', reply: 'Owner answered', decision: 'Decision' };
  return (
    <div className="stack">
      {notes.length ? <ul className="ad-list">{notes.map((n) => <li key={n.id}><span><b>{KIND[n.kind] ?? n.kind}</b> {n.body}</span><span className="ad-sub">{when(n.at)}{n.by ? ` · ${n.by}` : ''}</span></li>)}</ul> : <p className="small muted">No notes yet.</p>}
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => applicationNote(id, body), (r) => { if (r.ok) { setBody(''); router.refresh(); } }); }}>
        <div className={`field${a.err('body') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-b`}>Add a note (staff only)</label><textarea className="input" id={`${uid}-b`} rows={2} value={body} onChange={(e) => setBody(e.target.value)} data-testid="app-note" />
          <p className="error" role="alert">{a.err('body') ?? ''}</p></div>
        <div className="row"><button className="btn btn--ghost btn--sm" type="submit" disabled={a.pending} data-testid="app-note-add">Add note</button></div>
      </form>
    </div>
  );
}
