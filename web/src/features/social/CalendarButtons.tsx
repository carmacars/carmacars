'use client';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { regenerateCalendarPost, writeCalendarMonth } from '@/server/actions/social-calendar';

// The content calendar's two buttons that write (release 48, 3263): a month now, and one post again. Each shows it is
// working until the page has the new words; a refusal is shown as written.
export function WriteMonth({ month, label, primary = true }: { month: string; label: string; primary?: boolean }) {
  const a = useAct<{ added: number }>();
  const router = useRouter();
  return (
    <span className="rw-act">
      <button type="button" className={`btn ${primary ? 'btn--primary' : 'btn--ghost'} btn--sm`} disabled={a.pending} aria-busy={a.pending || undefined} data-testid="cal-write"
        onClick={() => a.run(() => writeCalendarMonth(month), (r) => { if (r.ok) router.refresh(); })}>{a.pending ? 'Writing' : label}</button>
      {a.res && (a.res.ok ? <span className="small" role="status" data-testid="cal-write-done">{a.res.data.added > 0 ? `${a.res.data.added} posts written. They wait for approval.` : 'Every day of this month was already written.'}</span>
        : <span className="error" role="alert" data-testid="cal-write-error">{a.res.message}</span>)}
    </span>
  );
}

export function Regenerate({ month, id }: { month: string; id: string }) {
  const a = useAct<{ id: string }>();
  const router = useRouter();
  return (
    <span className="rw-act">
      <button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} aria-busy={a.pending || undefined} data-testid={`cal-regen-${id.slice(0, 8)}`}
        onClick={() => a.run(() => regenerateCalendarPost(month, id), (r) => { if (r.ok) router.refresh(); })}>{a.pending ? 'Writing' : 'Regenerate'}</button>
      {a.res && !a.res.ok && <span className="error" role="alert">{a.res.message}</span>}
    </span>
  );
}
