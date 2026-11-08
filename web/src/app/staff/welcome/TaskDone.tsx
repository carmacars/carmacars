'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { welcomeTaskDone } from '@/server/actions/welcome';

// One first-day task's Done button on Welcome (0802).
export function TaskDone({ id, title }: { id: string; title: string }) {
  const [pending, start] = useTransition();
  const [err, setErr] = useState('');
  const router = useRouter();
  return (
    <span>
      <button type="button" className="btn btn--quiet btn--sm" disabled={pending} aria-label={`Done: ${title}`} data-testid="welcome-task-done"
        onClick={() => start(async () => { const r = await welcomeTaskDone(id); if (r.ok) router.refresh(); else setErr(r.message ?? 'Not saved.'); })}>{pending ? 'Saving' : 'Done'}</button>
      {err && <span className="small" role="alert"> {err}</span>}
    </span>
  );
}
