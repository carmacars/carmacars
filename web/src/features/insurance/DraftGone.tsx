'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { insuranceDo } from '@/server/actions/insurance';

// An unfinished rental opened from its link that is no longer open (5120): it says what became of it, instead of "already
// added or discarded", and a discarded one comes back with Restore (nothing typed is ever lost).
export function DraftGone({ draft, base }: { draft: { id: string; status: string; booking_number: string | null; closed_by: string | null; finished_at: string | null; data?: { form?: string } } | null; base: '/admin' | '/staff' | '/staff/field' }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  if (!draft) return <p className="alert alert--error" role="status" data-testid="draft-gone"><span>That unfinished rental is not there: it may have been typed on another account.</span></p>;
  const when = draft.finished_at ? new Date(draft.finished_at).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
  const form = draft.data?.form === 'insurer' ? `${base === '/staff/field' ? '/staff' : base}/insurance-replacements/new` : base === '/staff/field' ? '/staff/field/rentals/new' : `${base}/bookings/new`;
  if (draft.status === 'done') return <p className="alert alert--ok" role="status" data-testid="draft-gone"><span>That unfinished rental was added{draft.booking_number ? <> as <Link prefetch={false} className="link" href={`${base === '/staff/field' ? '/staff' : base}/bookings/${draft.booking_number}`}>{draft.booking_number}</Link></> : null}{when ? ` on ${when}` : ''}.</span></p>;
  return (
    <p className="alert alert--error" role="status" data-testid="draft-gone">
      <span>That unfinished rental was discarded{draft.closed_by ? ` by ${draft.closed_by}` : ''}{when ? ` on ${when}` : ''}. Nothing typed is lost: restore it to finish it.</span>
      <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid="draft-restore"
        onClick={() => start(async () => { const r = await insuranceDo('draft_restore', { id: draft.id }); if (!r.ok) { setErr(r.message); return; } router.push(`${form}?draft=${draft.id}`); router.refresh(); })}>Restore it</button>
      {err ? <span>{err}</span> : null}
    </p>);
}
