'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { listingProgress, listingRetryJob, listingSteps } from '@/server/actions/listing';

// The listing page's steps (migration 0521, replacing 0032's "Pipeline" numbers): "1 Photos (n of 14) > 2 Cover plates >
// 3 Review > 4 Live on the site", each with what it needs and one button. A step that stopped (a failed photo edit or
// copy) shows under them with its Retry. Reads again every few seconds while work is running, then refreshes the page
// so the draft and the photos show.
export interface Progress {
  intake_id: string; state: string; reason: string | null; decode_failed: boolean; draft_failed: boolean;
  total: number; done: number; running: number; waiting: number; failed: number; retrying: number; flagged_photos: number;
  cost_microusd: number; neurons: number; steps: Record<string, { total: number; done: number; failed: number }>;
  problems: Array<{ job_id: string; kind: string; status: string; attempts: number; max_attempts: number; error: string | null; next_attempt_at: string | null; shot: string | null }>;
}

const STEP: Record<string, string> = { decode_vin: 'Reading the VIN', draft_copy: 'Writing the copy', process_photo: 'Editing a photo', resize: 'Photo sizes', publish: 'Publishing' };
const busy = (p: Progress) => p.running + p.waiting > 0 && !['needs_review', 'published', 'cancelled', 'failed'].includes(p.state);

export interface Steps {
  intake_id: string; current: 1 | 2 | 3 | 4; live: boolean; slug: string | null; state: string;
  steps: Array<{ n: 1 | 2 | 3 | 4; key: 'photos' | 'plates' | 'review' | 'live'; title: string; done: boolean; need: string }>;
}

/** The one button of each step: where it leads on this page, or null when this person has nothing to press there. */
export function stepAction(s: Steps['steps'][number], o: { live: boolean; slug: string | null; canReview: boolean; hasCapture: boolean }): { label: string; href: string } | null {
  switch (s.key) {
    case 'photos': return o.hasCapture ? { label: s.done ? 'Change photos' : 'Add photos', href: '#lc-h' } : null;
    case 'plates': return o.canReview ? { label: 'Cover plates', href: '#lr-ph' } : null;
    case 'review': return o.canReview ? { label: s.done ? 'See the review' : 'Review', href: '#lr-chk' } : null;
    case 'live': return o.live && o.slug ? { label: 'See it on the site', href: `/cars/${o.slug}` } : o.canReview ? { label: 'Publish', href: '#lr-chk' } : null;
  }
}

export function ListingSteps({ initial, progress, refresh = [], canReview = false, hasCapture = true }:
  { initial: Steps; progress?: Progress | null; refresh?: string[]; canReview?: boolean; hasCapture?: boolean }) {
  const [st, setSt] = useState(initial);
  const [p, setP] = useState(progress ?? null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  useEffect(() => {
    if (!p || !busy(p)) return;
    const t = setTimeout(async () => {
      const [r, s] = await Promise.all([listingProgress<Progress>([p.intake_id]), listingSteps<Steps>(p.intake_id)]);
      const next = r.ok ? r.data[p.intake_id] : undefined;
      if (s.ok) setSt(s.data);
      if (next) { setP(next); if (next.state !== p.state || next.done !== p.done) router.refresh(); }
    }, 4000);
    return () => clearTimeout(t);
  }, [p, router]);
  const retry = (job: string) => start(async () => {
    const r = await listingRetryJob(job, refresh);
    setMsg(r.ok ? { ok: true, text: 'Queued again. It runs within a minute.' } : { ok: false, text: r.message });
    const again = await listingProgress<Progress>([st.intake_id]);
    if (again.ok && again.data[st.intake_id]) setP(again.data[st.intake_id]!);
    router.refresh();
  });
  const working = p && busy(p);
  return (
    <section className="pt-card ad-card ls" aria-labelledby="ls-h" data-testid="listing-steps" data-current={st.live ? 'live' : st.current}>
      <h2 className="d4" id="ls-h">Steps to go live</h2>
      <ol className="ls__steps">
        {st.steps.map((s) => {
          const now = !st.live && s.n === st.current;
          const a = stepAction(s, { live: st.live, slug: st.slug, canReview, hasCapture });
          return (
            <li key={s.key} className={`ls__step${s.done ? ' is-done' : ''}${now ? ' is-now' : ''}`} data-step={s.key} aria-current={now ? 'step' : undefined}>
              <span className="ls__n" aria-hidden="true">{s.done ? <Tick /> : s.n}</span>
              <span className="ls__body">
                <b className="ls__title"><span className="vh">{s.n}. </span>{s.title}{s.done && <span className="vh"> (done)</span>}</b>
                <span className="small muted ls__need">{s.need}</span>
                {a && <a className={`btn btn--sm ${now || (s.key === 'live' && st.live) ? 'btn--primary' : 'btn--ghost'} ls__go`} href={a.href} data-testid={`step-${s.key}`}>{a.label}</a>}
              </span>
            </li>
          );
        })}
      </ol>
      {working && <p className="small muted ls__working" role="status">Working on it: {p!.done} of {p!.total} done. This page updates by itself.</p>}
      {p && (p.decode_failed || p.draft_failed || p.flagged_photos > 0) && <ul className="small lp__flags">
        {p.decode_failed && <li>The VIN could not be read automatically: enter the details from the ownership permit.</li>}
        {p.draft_failed && <li>The copy draft failed: retry it, or write the copy in the review.</li>}
        {p.flagged_photos > 0 && <li>{p.flagged_photos} photo{p.flagged_photos > 1 ? 's' : ''} kept as taken or flagged: check them before approving.</li>}
      </ul>}
      {p && p.problems.length > 0 && <ul className="lp__problems" data-testid="listing-problems">{p.problems.map((x) => (
        <li key={x.job_id}>
          <span><b>{STEP[x.kind] ?? x.kind}{x.shot ? `: ${x.shot}` : ''}</b> · {x.status === 'failed' ? 'stopped' : `trying again (attempt ${x.attempts} of ${x.max_attempts})`}</span>
          {x.error && <span className="small muted lp__err">{x.error}</span>}
          <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => retry(x.job_id)} data-testid="listing-retry">{x.status === 'failed' ? 'Retry' : 'Retry now'}</button>
        </li>))}</ul>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}

function Tick() {
  return <svg viewBox="0 0 16 16" width="14" height="14" focusable="false"><path d="M3 8.5l3 3 7-7" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>;
}

/** A compact bar for the list pages. */
export function ProgressCell({ p }: { p: Progress | undefined }) {
  if (!p || !p.total) return <span className="muted small">No steps yet</span>;
  const pct = Math.round((p.done / p.total) * 100);
  return (
    <span className="lp-cell" title={`${p.done} of ${p.total} steps done`}>
      <span className="lp__bar lp__bar--sm" aria-hidden="true"><span style={{ width: `${pct}%` }} /></span>
      <span className="small">{p.done}/{p.total}{p.failed ? <b className="ad-late"> · {p.failed} failed</b> : p.retrying ? ` · ${p.retrying} retrying` : ''}</span>
    </span>
  );
}
