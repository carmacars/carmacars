'use client';
import { useState, useTransition } from 'react';
import Link from '@/components/Link';
import { PortalIcon, type PortalIconName } from '@/components/portal-ui/icons';
import { walkthroughGotIt } from '@/server/actions/walkthrough';
import { STAGES, walkView, type Facts, type View, type Walk } from './model';

// The rental walkthrough (migration 0291): the step to do now on top, then every step by stage. A step to read has
// "Got it"; a task has its own page and is done when it is done.
export function Walkthrough({ initial, facts }: { initial: Walk; facts: Facts }) {
  const [w, setW] = useState(initial);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [, start] = useTransition();
  const v = walkView(w, facts);
  const at = STAGES.findIndex((s) => s.key === v.stage);
  const gotIt = (key: string) => start(async () => {
    setErr(null); setBusy(key);
    const r = await walkthroughGotIt(facts.number, key).catch(() => null);
    setBusy(null);
    if (!r?.ok) { setErr(r?.message ?? 'No connection. Try again.'); return; }
    setW(r.data);
  });
  const pct = v.total ? Math.round((v.done / v.total) * 100) : 0;
  return (
    <div className="wk" data-testid="walkthrough">
      <div className="wk-progress" data-testid="walk-progress">
        <div className="wk-progress__top"><b>{v.done} of {v.total} done</b><span>{v.now ? STAGES[at]?.title : 'All done'}</span></div>
        <div className="wk-progress__bar" role="progressbar" aria-valuemin={0} aria-valuemax={v.total} aria-valuenow={v.done} aria-label="Steps done"><span style={{ width: `${pct}%` }} /></div>
        <ol className="wk-stages" aria-label="Stages of your rental">
          {STAGES.map((s, i) => <li key={s.key} className={i < at ? 'is-past' : i === at ? 'is-now' : ''} aria-current={i === at ? 'step' : undefined}><span className="wk-stages__n">{i + 1}</span><span className="wk-stages__t">{s.title}</span></li>)}
        </ol>
      </div>

      {v.now ? (
        <section className="wk-now" aria-labelledby="wk-now-h" data-testid="walk-now" data-step={v.now.key}>
          <p className="wk-now__kicker">{STAGES.find((s) => s.key === v.now!.stage)?.title} · Next</p>
          <div className="wk-now__head"><span className="wk-ico wk-ico--big"><PortalIcon name={v.now.icon as PortalIconName} size={24} /></span><h2 className="wk-now__title" id="wk-now-h">{v.now.title}</h2></div>
          <Body s={v.now} />
          <Actions s={v.now} busy={busy} onGotIt={gotIt} primary />
        </section>
      ) : (
        <section className="wk-now wk-now--done" data-testid="walk-all-done"><div className="wk-now__head"><span className="wk-ico wk-ico--big"><PortalIcon name="check" size={24} /></span><h2 className="wk-now__title">Every step is done</h2></div>
          <p className="wk-now__body">Thank you for renting with us. Your statement and receipts are on your booking.</p></section>
      )}
      {err && <p className="pscan__err" role="alert">{err}</p>}

      {STAGES.map((s, i) => {
        const list = v.views.filter((x) => x.stage === s.key);
        if (!list.length) return null;
        const done = list.filter((x) => x.state === 'done').length;
        return (
          <section key={s.key} className={`wk-stage${i === at ? ' is-now' : ''}`} aria-labelledby={`wk-${s.key}`} data-testid={`walk-stage-${s.key}`}>
            <div className="wk-stage__head"><h2 className="wk-stage__title" id={`wk-${s.key}`}><span className="wk-stages__n">{i + 1}</span>{s.title}</h2><span className="wk-stage__count">{done} of {list.length}</span></div>
            <ol className="wk-list">
              {list.map((x) => (
                <li key={x.key} className={`wk-step is-${x.state}`} data-testid={`walk-step-${x.key}`} data-state={x.state}>
                  <span className="wk-ico" aria-hidden="true">{x.state === 'done' ? <PortalIcon name="check" size={18} /> : <PortalIcon name={x.icon as PortalIconName} size={18} />}</span>
                  <div className="wk-step__main">
                    <p className="wk-step__title">{x.title}<span className="vh">{x.state === 'done' ? ' (done)' : x.state === 'now' ? ' (next)' : ''}</span></p>
                    {x.state !== 'now' && <Body s={x} small />}
                    {x.state !== 'now' && <Actions s={x} busy={busy} onGotIt={gotIt} />}
                    {x.state === 'now' && <p className="wk-step__see">Shown above</p>}
                  </div>
                </li>))}
            </ol>
          </section>);
      })}
      {facts.phone && <p className="small muted wk-foot">Questions at any step? Call us at <a className="link" href={`tel:${facts.phone.replace(/[^\d+]/g, '')}`}>{facts.phone}</a> or message us on your booking.</p>}
    </div>
  );
}

function Body({ s, small }: { s: View; small?: boolean }) {
  return (<>
    <p className={small ? 'wk-step__body' : 'wk-now__body'}>{s.body}</p>
    {s.points.length > 0 && <ul className={small ? 'wk-points wk-points--sm' : 'wk-points'}>{s.points.map((p) => <li key={p}>{p}</li>)}</ul>}
  </>);
}

function Actions({ s, busy, onGotIt, primary }: { s: View; busy: string | null; onGotIt: (k: string) => void; primary?: boolean }) {
  const ext = s.cta?.href.startsWith('http');
  const read = s.read && s.state !== 'done';
  if (!s.cta && !read) return null;
  return (
    <div className="wk-actions">
      {s.cta && (ext ? <a className={`btn btn--sm ${primary && !read ? 'btn--primary' : 'btn--ghost'}`} href={s.cta.href} target="_blank" rel="noreferrer">{s.cta.label}</a>
        : <Link prefetch={false} className={`btn btn--sm ${primary && !read ? 'btn--primary' : 'btn--ghost'}`} href={s.cta.href} data-testid={`walk-cta-${s.key}`}>{s.cta.label}</Link>)}
      {read && <button type="button" className={`btn btn--sm ${primary ? 'btn--primary' : 'btn--ghost'}`} disabled={busy === s.key} onClick={() => onGotIt(s.key)} data-testid={`walk-got-${s.key}`}>{busy === s.key ? 'Saving' : 'Got it'}</button>}
    </div>
  );
}
