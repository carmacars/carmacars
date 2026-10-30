'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { agreementWordingSave } from '@/server/actions/agreements';

// "Edit the wording" on the booking's Agreement card (migration 0198): an Admin rewords a clause of CarmaCars' rental
// agreement for this booking, adds additional terms, or removes a clause that is not required, always with a reason.
// Before signing the open agreement is made again; after signing the change is a new version the renter signs.
export interface WordingClause { code: string; part: string; title: string; removable: boolean; editable: boolean; standard: string }
export interface WordingChange { id: string; code: string; action: string; text: string | null; reason: string; at: string; by: string | null }
type Now = Record<string, { action: string; text: string | null }>;

const ACTION: Record<string, string> = { edit: 'reworded', add: 'written', remove: 'removed', restore: 'back to standard' };

export function AgreementWording({ booking, clauses, now, history, refresh }: { booking: string; clauses: WordingClause[]; now: Now; history: WordingChange[]; refresh: string[] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [code, setCode] = useState<string | null>(null);
  const [text, setText] = useState('');
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const changed = Object.keys(now).length;
  const list = clauses;
  const pick = (c: WordingClause) => { setCode(c.code); setText(now[c.code]?.text ?? c.standard); setReason(''); setMsg(null); };
  const save = (action: 'edit' | 'add' | 'remove' | 'restore') => start(async () => {
    if (!code) return;
    const r = await agreementWordingSave(booking, { code, action, text: action === 'edit' || action === 'add' ? text : undefined, reason }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: r.data.agreement === 'completed'
      ? 'Saved. A new version of the agreement is made for the renter to sign.'
      : 'Saved. The agreement is made again with this wording.' });
    setCode(null); router.refresh();
  });
  if (!open) return (
    <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'center' }}>
      <button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(true)} data-testid="agreement-wording-open">Edit the wording</button>
      {changed > 0 && <span className="small" data-testid="agreement-wording-count">{changed} clause{changed === 1 ? '' : 's'} worded for this booking</span>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </div>
  );
  const c = code ? list.find((x) => x.code === code) ?? null : null;
  const cur = c ? now[c.code] : undefined;
  const isAdd = c?.code === 'additional';
  return (
    <div className="stack" data-testid="agreement-wording">
      <p className="small">The wording of <b>CarmaCars&apos; rental agreement</b> for this booking only. Blind Spot&apos;s agreement is the insurer&apos;s official form: its printed terms are not changed. Clauses marked <b>required</b> are needed by law or the insurer: they can be reworded, not removed. Before the renter signs, the agreement is simply made again; after signing, a change is a new version the renter signs.</p>
      <ul className="stack" style={{ paddingLeft: 0, listStyle: 'none' }}>
        {list.map((x) => (
          <li key={x.code} className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)', alignItems: 'center' }} data-testid={`wording-clause-${x.code}`}>
            <span style={{ flex: '1 1 14rem' }}>{x.title}{!x.removable && x.editable ? <span className="xs muted"> · required</span> : null}{!x.editable ? <span className="xs muted"> · fixed (the consents the signer ticks)</span> : null}
              {now[x.code] && <b className="small"> · {ACTION[now[x.code]!.action] ?? now[x.code]!.action}</b>}</span>
            {x.editable && <button className="btn btn--quiet btn--sm" type="button" onClick={() => pick(x)} data-testid={`wording-pick-${x.code}`}>{x.code === 'additional' ? (now[x.code] ? 'Change' : 'Add') : 'Change'}</button>}
          </li>))}
      </ul>
      {c && (
        <form className="stack" onSubmit={(e) => { e.preventDefault(); save(isAdd ? 'add' : 'edit'); }} data-testid="wording-form">
          <label className="field" style={{ margin: 0 }}><span className="label">{c.title}: the text for this booking (**bold** and lines starting with “- ” for a list)</span>
            <textarea className="input" rows={12} value={text} onChange={(e) => setText(e.target.value)} data-testid="wording-text" /></label>
          {!isAdd && <details><summary className="link small">The standard wording</summary><pre className="small" style={{ whiteSpace: 'pre-wrap' }}>{c.standard}</pre></details>}
          <label className="field" style={{ margin: 0 }}><span className="label">Why this booking needs it (kept with the change)</span>
            <input className="input" value={reason} minLength={5} onChange={(e) => setReason(e.target.value)} data-testid="wording-reason" /></label>
          <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-2)' }}>
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending || reason.trim().length < 5 || !text.trim()} data-testid="wording-save">{pending ? 'Saving' : 'Save the wording'}</button>
            {c.removable && cur?.action !== 'remove' && (isAdd ? !!cur : true) && <button className="btn btn--ghost btn--sm" type="button" disabled={pending || reason.trim().length < 5} onClick={() => save('remove')} data-testid="wording-remove">{isAdd ? 'Remove the additional terms' : 'Remove this clause'}</button>}
            {cur && !isAdd && <button className="btn btn--ghost btn--sm" type="button" disabled={pending || reason.trim().length < 5} onClick={() => save('restore')} data-testid="wording-restore">Back to the standard wording</button>}
            <button className="btn btn--quiet btn--sm" type="button" onClick={() => setCode(null)}>Cancel</button>
          </div>
        </form>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      {history.length > 0 && <details data-testid="wording-history"><summary className="link small">Wording changes ({history.length})</summary>
        <ul className="small">{history.map((h) => <li key={h.id}>{h.at.slice(0, 16).replace('T', ' ')}, {h.by ?? 'an Admin'}: {list.find((x) => x.code === h.code)?.title ?? h.code} {ACTION[h.action] ?? h.action}. Reason: {h.reason}</li>)}</ul></details>}
      <div><button className="btn btn--quiet btn--sm" type="button" onClick={() => { setOpen(false); setCode(null); }}>Close</button></div>
    </div>
  );
}
