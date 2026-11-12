'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { leadAct } from '@/server/actions/sales-leads';
import { BEFORE_TODAY_FILTER, bulkWords, type BulkResult, type Person } from './model';

export const BULK_FORM = 'sl-bulk';
const picked = () => Array.from(document.querySelectorAll<HTMLInputElement>(`input[form="${BULK_FORM}"][name="ids"]`));

/** The Admin's bulk assignment (2411) above the lead list: the chosen cards, or everything the list's filter matches, to a
 *  Sales person or back to the pool; and every open lead nobody has that came in before today, in one press. Each asks first
 *  with the count. The database caps a press at 500 and says how many are left. */
export function BulkAssign({ people, filter, count }: { people: Person[]; filter: Record<string, unknown>; count: number }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [scope, setScope] = useState<'chosen' | 'filter'>('chosen');
  const [to, setTo] = useState('');
  const run = (target: Record<string, unknown>, what: string) => start(async () => {
    const dest = to === 'pool' ? { pool: true } : { to };
    if (!to) { setMsg({ ok: false, text: 'Choose who gets the leads, or Return to the pool.' }); return; }
    const pre = await leadAct<BulkResult>('leads_bulk_assign', { ...target, ...dest, preview: true });
    if (!pre.ok) { setMsg({ ok: false, text: pre.message }); return; }
    if (!pre.data.matched) { setMsg({ ok: false, text: 'No open lead matches.' }); return; }
    const name = to === 'pool' ? 'back to the pool' : `to ${people.find((p) => p.id === to)?.name ?? 'them'}`;
    if (!window.confirm(`${what}: ${bulkWords(pre.data)}\nMove ${Math.min(pre.data.matched, pre.data.cap)} ${name}?`)) return;
    const r = await leadAct<BulkResult>('leads_bulk_assign', { ...target, ...dest });
    setMsg(r.ok ? { ok: true, text: bulkWords(r.data) } : { ok: false, text: r.message });
    if (r.ok) { for (const i of picked()) i.checked = false; router.refresh(); }
  });
  const go = () => {
    if (scope === 'filter') return run({ filter }, `Every open lead this list's filter matches (${count})`);
    const ids = picked().filter((i) => i.checked).map((i) => i.value);
    if (!ids.length) { setMsg({ ok: false, text: 'Tick at least one lead, or choose Everything the filter matches.' }); return; }
    run({ ids }, `${ids.length} chosen`);
  };
  return (
    <form id={BULK_FORM} className="sl-bulk" onSubmit={(e) => { e.preventDefault(); go(); }} data-testid="lead-bulk" aria-label="Assign leads in bulk">
      <b className="small">Assign in bulk</b>
      <button type="button" className="btn btn--ghost btn--sm" onClick={() => { const all = picked(); const on = all.some((i) => !i.checked); for (const i of all) i.checked = on; setScope('chosen'); }} data-testid="lead-bulk-all">Select all on this page</button>
      <label className="small row" style={{ gap: 'var(--s-1)' }}>Which
        <select value={scope} onChange={(e) => setScope(e.target.value as 'chosen' | 'filter')} data-testid="lead-bulk-scope">
          <option value="chosen">The ticked leads</option>
          <option value="filter">Everything the filter matches</option>
        </select>{scope === 'filter' && <span className="muted" data-testid="lead-bulk-count">({count} in the list)</span>}</label>
      <label className="small row" style={{ gap: 'var(--s-1)' }}>Assign to
        <select value={to} onChange={(e) => setTo(e.target.value)} data-testid="lead-bulk-to">
          <option value="">Choose…</option>
          {people.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          <option value="pool">Return to the pool</option>
        </select></label>
      <button type="submit" className="btn btn--primary btn--sm" disabled={pending} data-testid="lead-bulk-go">Assign</button>
      <button type="button" className="btn btn--ghost btn--sm" disabled={pending} onClick={() => run({ filter: BEFORE_TODAY_FILTER }, 'Every open lead nobody has that came in before today')} data-testid="lead-bulk-old">Assign every unassigned lead older than today</button>
      {msg && <p className={`small ${msg.ok ? '' : 'rc-red'}`} role={msg.ok ? 'status' : 'alert'} style={{ flexBasis: '100%', margin: 0 }} data-testid="lead-bulk-msg">{msg.text}</p>}
      {!people.length && <p className="small muted" style={{ flexBasis: '100%', margin: 0 }}>Nobody can take leads yet: only active, fully onboarded Sales staff can.</p>}
    </form>
  );
}
