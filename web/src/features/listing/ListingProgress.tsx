'use client';
import { useEffect, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { listingProgress, listingRetryJob } from '@/server/actions/listing';

// The pipeline's progress for one listing (09-listing-pipeline.md section 5.5): steps done, running and
// waiting, the failures with their errors and a Retry for each, and what the run cost. Reads again every
// few seconds while work is running, then refreshes the page so the draft and the photos show.
export interface Progress {
  intake_id: string; state: string; reason: string | null; decode_failed: boolean; draft_failed: boolean;
  total: number; done: number; running: number; waiting: number; failed: number; retrying: number; flagged_photos: number;
  cost_microusd: number; neurons: number; steps: Record<string, { total: number; done: number; failed: number }>;
  problems: Array<{ job_id: string; kind: string; status: string; attempts: number; max_attempts: number; error: string | null; next_attempt_at: string | null; shot: string | null }>;
}

const STEP: Record<string, string> = { decode_vin: 'VIN decode', draft_copy: 'Copy draft', process_photo: 'Photo backgrounds', resize: 'Photo sizes', publish: 'Publish' };
const STATE: Record<string, string> = {
  started: 'Waiting for photos', decoding: 'Reading the VIN', photos_uploaded: 'Photos in, ready to submit', drafting: 'Writing the copy',
  processing_photos: 'Editing the photos', needs_review: 'Ready for review', approved: 'Approved', published: 'Live on the website', failed: 'Stopped: needs a retry', cancelled: 'Cancelled'
};
const busy = (p: Progress) => p.running + p.waiting > 0 && !['needs_review', 'published', 'cancelled', 'failed'].includes(p.state);

export function ListingProgress({ initial, refresh = [] }: { initial: Progress; refresh?: string[] }) {
  const [p, setP] = useState(initial);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  useEffect(() => {
    if (!busy(p)) return;
    const t = setTimeout(async () => {
      const r = await listingProgress<Progress>([p.intake_id]);
      const next = r.ok ? r.data[p.intake_id] : undefined;
      if (next) { setP(next); if (next.state !== p.state || next.done !== p.done) router.refresh(); }
    }, 4000);
    return () => clearTimeout(t);
  }, [p, router]);
  const pct = p.total ? Math.round((p.done / p.total) * 100) : 0;
  const retry = (job: string) => start(async () => {
    const r = await listingRetryJob(job, refresh);
    setMsg(r.ok ? { ok: true, text: 'Queued again. It runs within a minute.' } : { ok: false, text: r.message });
    const again = await listingProgress<Progress>([p.intake_id]);
    if (again.ok && again.data[p.intake_id]) setP(again.data[p.intake_id]!);
    router.refresh();
  });
  return (
    <section className="pt-card ad-card lp" aria-labelledby="lp-h" data-testid="listing-progress" data-state={p.state}>
      <h2 className="d4" id="lp-h">Pipeline</h2>
      <p className="lp__state"><b>{STATE[p.state] ?? p.state}</b>{p.total > 0 && <span className="muted small"> · {p.done} of {p.total} steps done</span>}</p>
      <div className="lp__bar" role="progressbar" aria-label="Steps done" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct}><span style={{ width: `${pct}%` }} /></div>
      {Object.keys(p.steps).length > 0 && <ul className="lp__steps">{Object.entries(p.steps).map(([k, s]) => (
        <li key={k} className={s.failed ? 'is-bad' : s.done === s.total ? 'is-done' : ''}><span>{STEP[k] ?? k}</span><span>{s.done}/{s.total}{s.failed ? `, ${s.failed} failed` : ''}</span></li>))}</ul>}
      {(p.decode_failed || p.draft_failed || p.flagged_photos > 0) && <ul className="small lp__flags">
        {p.decode_failed && <li>The VIN could not be read automatically: enter the details from the ownership permit.</li>}
        {p.draft_failed && <li>The copy draft failed: retry it, or write the copy in the review.</li>}
        {p.flagged_photos > 0 && <li>{p.flagged_photos} photo{p.flagged_photos > 1 ? 's' : ''} kept as taken or flagged: check them before approving.</li>}
      </ul>}
      {p.problems.length > 0 && <ul className="lp__problems" data-testid="listing-problems">{p.problems.map((x) => (
        <li key={x.job_id}>
          <span><b>{STEP[x.kind] ?? x.kind}{x.shot ? `: ${x.shot}` : ''}</b> · {x.status === 'failed' ? 'failed' : `retrying (attempt ${x.attempts} of ${x.max_attempts})`}</span>
          {x.error && <span className="small muted lp__err">{x.error}</span>}
          <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => retry(x.job_id)} data-testid="listing-retry">{x.status === 'failed' ? 'Retry' : 'Retry now'}</button>
        </li>))}</ul>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      {p.cost_microusd > 0 || p.neurons > 0 ? <p className="small muted">Provider cost so far: US${(p.cost_microusd / 1_000_000).toFixed(4)}{p.neurons ? ` · ${Math.round(p.neurons)} neurons` : ''}</p> : null}
    </section>
  );
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
