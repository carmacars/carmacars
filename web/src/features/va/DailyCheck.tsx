'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';

// The opening or closing check (procedure 19; 05-va.md section 3.5): each line OK or Problem with a note.
// The lines the system can answer arrive pre-answered with what it found; the assistant confirms. Any
// Problem escalates to an Admin.
export interface Item { n: number; label: string; system: boolean | null; detail: string | null }
type A = { result: 'ok' | 'problem' | ''; note: string };

export function DailyCheck({ kind, date, items, saved }: { kind: 'opening' | 'closing'; date: string; items: Item[]; saved: Record<string, { result: string; note?: string }> | null }) {
  const router = useRouter();
  const [a, setA] = useState<Record<number, A>>(() => Object.fromEntries(items.map((i) => {
    const s = saved?.[String(i.n)];
    return [i.n, { result: (s?.result as A['result']) ?? (i.system === true ? 'ok' : i.system === false ? 'problem' : ''), note: s?.note ?? (i.system === false && i.detail ? i.detail : '') }];
  })));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (n: number, p: Partial<A>) => setA((x) => ({ ...x, [n]: { ...x[n]!, ...p } }));
  return (
    <form className="ad-check" data-testid={`check-${kind}`} onSubmit={(e) => { e.preventDefault(); start(async () => {
      const r = await vaAct<{ problems: number }>('daily_check_save', { kind, date, items: Object.fromEntries(Object.entries(a).map(([n, v]) => [n, { result: v.result, note: v.note.trim() || null }])) });
      setMsg(r.ok ? { ok: true, text: r.data.problems ? `Saved. ${r.data.problems} problem(s) sent to an Admin.` : 'Saved. All clear.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    }); }}>
      {items.map((i) => (
        <fieldset key={i.n} className={`ad-check__line${a[i.n]?.result === 'problem' ? ' is-problem' : ''}`}>
          <legend className="small"><b>{i.n}. {i.label}</b></legend>
          {i.detail && <p className="small muted">{i.system === null ? '' : 'Found: '}{i.detail}</p>}
          <div className="ad-check__choice" role="radiogroup" aria-label={`Line ${i.n}`}>
            {(['ok', 'problem'] as const).map((r) => (
              <label key={r} className="check"><input type="radio" name={`l${i.n}`} value={r} checked={a[i.n]?.result === r} onChange={() => set(i.n, { result: r })} /> <span>{r === 'ok' ? 'OK' : 'Problem'}</span></label>))}
          </div>
          {a[i.n]?.result === 'problem' && <div className="field"><label className="label" htmlFor={`note-${kind}-${i.n}`}>What is the problem</label>
            <input className="input" id={`note-${kind}-${i.n}`} value={a[i.n]?.note ?? ''} onChange={(e) => set(i.n, { note: e.target.value })} required /></div>}
        </fieldset>
      ))}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={pending} data-testid={`check-save-${kind}`}>{pending ? 'Saving' : `Save the ${kind} check`}</button>
    </form>
  );
}
