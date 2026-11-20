'use client';
import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { answerDataCheck, saveDataFix } from '@/server/actions/data-checks';
import { AddressInput } from '@/features/forms/AddressInput';
import { closable, inputsOf, order, type DataIssue } from './model';

// r48 FE (3197): on sign-in and every portal page, a pop-up that names exactly what looks wrong on the person's own record,
// with the input to fix it right there. Saving checks again and closes it when nothing is left. A blocking issue (the
// staff agreement needs it, an expired licence) keeps it open; a warning closes with Remind me later (back in 24 hours),
// and some take "It's correct" with the reason.
export function DataCheckModal({ issues: first, inline = false }: { issues: DataIssue[]; /** on a page (the sign pages), not a pop-up */ inline?: boolean }) {
  const router = useRouter();
  const [issues, setIssues] = useState(() => order(first));
  const [hidden, setHidden] = useState(false);
  const ref = useRef<HTMLDialogElement>(null);
  // new issues from the server (after a refresh) replace the list: adjusted while rendering, not in an effect
  const [prev, setPrev] = useState(first);
  if (prev !== first) { setPrev(first); setIssues(order(first)); }
  const open = issues.length > 0 && !hidden;
  useEffect(() => {
    const d = ref.current;
    if (inline || !d) return;
    if (open && !d.open) { try { d.showModal(); } catch { d.setAttribute('open', ''); } }
    if (!open && d.open) d.close();
  }, [open, inline]);
  if (!issues.length) return null;
  const canClose = closable(issues);
  const body = (
    <div className="stack" data-testid="data-check">
      <h2 className="d4" id="dc-title">{issues.length === 1 ? 'One thing to check on your record' : `${issues.length} things to check on your record`}</h2>
      {issues.map((i) => <IssueForm key={i.key} i={i} done={(open2, note) => { setIssues(order(open2)); if (note) router.refresh(); }} />)}
      {canClose && !inline && <p className="ad-actions"><button type="button" className="btn btn--ghost btn--sm" data-testid="data-check-later"
        onClick={() => { void Promise.all(issues.map((i) => answerDataCheck(i.key, 'dismiss'))); setHidden(true); }}>Remind me later</button></p>}
    </div>
  );
  if (inline) return <section className="pt-card">{body}</section>;
  return (
    <dialog ref={ref} className="pt-card" aria-labelledby="dc-title" aria-modal="true" style={{ maxWidth: 560, width: 'calc(100% - 32px)', overscrollBehavior: 'contain' }}
      onCancel={(e) => { if (!canClose) e.preventDefault(); else setHidden(true); }}>{body}</dialog>
  );
}

function IssueForm({ i, done }: { i: DataIssue; done: (open: DataIssue[], refresh: boolean) => void }) {
  const inputs = inputsOf(i);
  const [v, setV] = useState<Record<string, string | boolean>>(() => Object.fromEntries(inputs.map((x) => [x.name, x.type === 'check' ? false : x.value ?? ''])));
  const [why, setWhy] = useState('');
  const [mode, setMode] = useState<'fix' | 'confirm'>('fix');
  const [err, setErr] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const save = () => start(async () => {
    setErr(null);
    const r = mode === 'confirm' ? await answerDataCheck(i.key, 'confirm', why)
      : await saveDataFix(i.fix.kind ?? '', i.audience, v);
    if (!r.ok) { setErr(r.message); return; }
    if ('agreement' in r && r.agreement === 'sent') setNote('Your agreement is ready: open Documents to sign.');
    done(r.open, true);
  });
  return (
    <div className={`stack${i.severity === 'blocking' ? ' is-warn' : ''}`} data-testid={`data-check-${i.key}`} data-severity={i.severity}>
      <p className={i.severity === 'blocking' ? 'alert alert--error' : 'alert alert--warn'} role="status"><span>{i.message}</span></p>
      {i.fix.kind === 'link' ? <p><Link prefetch={false} className="btn btn--primary btn--sm" href={i.fix.href ?? '/'}>{i.fix.label ?? 'Fix it'}</Link></p> : <>
        {i.allow_confirm && <p className="ad-actions">
          <button type="button" className={`btn btn--sm ${mode === 'fix' ? 'btn--primary' : 'btn--ghost'}`} onClick={() => setMode('fix')}>Fix it</button>
          <button type="button" className={`btn btn--sm ${mode === 'confirm' ? 'btn--primary' : 'btn--ghost'}`} onClick={() => setMode('confirm')} data-testid={`data-check-correct-${i.key}`}>It&apos;s correct</button></p>}
        {mode === 'confirm'
          ? <label className="field"><span className="label">Why it is correct</span><input className="input" value={why} onChange={(e) => setWhy(e.target.value)} data-testid={`data-check-why-${i.key}`} /></label>
          : inputs.map((x) => x.type === 'check'
            ? <label key={x.name} className="check"><input type="checkbox" checked={Boolean(v[x.name])} onChange={(e) => setV({ ...v, [x.name]: e.target.checked })} /> <span>{x.label}</span></label>
            : x.type === 'address'
              ? <div key={x.name} className="field"><label className="label" htmlFor={`dc-${i.key}-${x.name}`}>{x.label}</label>
                  <AddressInput id={`dc-${i.key}-${x.name}`} name={x.name} anywhere value={{ label: String(v[x.name] ?? ''), placeId: '' }} onChange={(a) => setV({ ...v, [x.name]: a.label })} testId={`data-check-${i.key}-${x.name}`} /></div>
            : <label key={x.name} className="field"><span className="label">{x.label}</span>
                <input className="input" type={x.type} inputMode={x.type === 'tel' ? 'tel' : undefined} autoComplete={x.type === 'tel' ? 'tel' : undefined} value={String(v[x.name] ?? '')} onChange={(e) => setV({ ...v, [x.name]: e.target.value })} data-testid={`data-check-${i.key}-${x.name}`} /></label>)}
        <p><button type="button" className="btn btn--primary btn--sm" disabled={pending} onClick={save} data-testid={`data-check-save-${i.key}`}>{pending ? 'Saving' : 'Save'}</button></p>
      </>}
      {err && <p className="error" role="alert">{err}</p>}
      {note && <p className="small" role="status">{note}</p>}
    </div>
  );
}
