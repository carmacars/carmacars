'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import Link from '@/components/Link';
import { leadAct } from '@/server/actions/sales-leads';
import { age, type LeadDuplicate } from './model';

// Duplicate leads (release 48, migration 3230): the other leads of the same person (same email, phone or browser), each
// with one Merge button. The older lead is kept; the other's message, calls, texts, chats and notes move to it.
export function LeadDuplicates({ lead, rows, base }: { lead: string; rows: LeadDuplicate[]; base: string }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const router = useRouter();
  const run = (action: string, p: Record<string, unknown>, okText: string, key: string) => start(async () => {
    const r = await leadAct<{ kept?: string; merged?: number }>(action, { lead, ...p });
    setMsg(r.ok ? { ok: true, text: okText } : { ok: false, text: r.message });
    if (!r.ok) return;
    setDone(key);
    // the lead that was kept may be the other one: its page is where the work goes on
    if (r.data?.kept && r.data.kept !== lead) router.replace(`${base}/${r.data.kept}`); else router.refresh();
  });
  if (!rows.length) return null;
  return (
    <div className="stack sl-dups" data-testid="lead-duplicates" style={{ gap: 'var(--s-3)' }}>
      <p className="small">The same person wrote more than once. Merge keeps the oldest lead and moves everything from the other onto it: the message, calls, texts, chats and notes. Nothing is deleted.</p>
      <ul className="sl-dups__list">
        {rows.map((d) => (
          <li key={d.id} className="sl-dups__row" data-testid="lead-duplicate" data-merged={done === d.id ? 'yes' : undefined}>
            <div className="sl-dups__who">
              <Link prefetch={false} className="link" href={`${base}/${d.id}`}><b>{d.name ?? d.phone ?? d.email ?? 'Lead'}</b></Link>
              <span className="small muted">{d.source} · {age(d.created_at)} · {d.handled ? 'handled' : d.outcome ?? d.status} · {d.why}</span>
              {d.excerpt && <span className="small sl-dups__text">{d.excerpt}</span>}
            </div>
            <div className="row sl-dups__go">
              <button type="button" className="btn btn--primary btn--sm" disabled={pending} aria-busy={pending || undefined} onClick={() => run('lead_merge', { other: d.id }, 'Merged.', d.id)} data-testid="lead-merge">Merge</button>
              <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => run('lead_not_duplicate', { other: d.id }, 'Kept apart. We will not suggest this pair again.', d.id)} data-testid="lead-not-duplicate">Different person</button>
            </div>
          </li>))}
      </ul>
      {rows.length > 1 && <div><button type="button" className="btn btn--ghost btn--sm" disabled={pending} aria-busy={pending || undefined} onClick={() => run('lead_merge_all', {}, 'All merged into the oldest lead.', 'all')} data-testid="lead-merge-all">Merge all {rows.length + 1} into the oldest</button></div>}
      {msg && <p className={`small ${msg.ok ? 'sl-dups__ok' : 'form-error'}`} role="status" data-testid="lead-merge-msg">{msg.text}</p>}
    </div>
  );
}
