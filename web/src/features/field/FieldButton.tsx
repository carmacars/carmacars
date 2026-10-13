'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { fieldAct } from '@/server/actions/field';

type A = Parameters<typeof fieldAct>[0];
// One step on a job card or a small form (acknowledge, start, vehicle moves, damage found later).
export function FieldButton({ action, payload, label, testId, primary, fields }: { action: A; payload: Record<string, unknown>; label: string; testId?: string; primary?: boolean;
  fields?: Array<{ name: string; label: string; numeric?: boolean; options?: Array<[string, string]>; required?: boolean }> }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [vals, setVals] = useState<Record<string, string>>(() => Object.fromEntries((fields ?? []).map((f) => [f.name, f.options?.[0]?.[0] ?? ''])));
  const run = () => start(async () => {
    setErr(null);
    const extra: Record<string, unknown> = {};
    for (const f of fields ?? []) { const v = vals[f.name]?.trim() ?? ''; if (f.required && !v) { setErr(`${f.label} is required.`); return; } if (v) extra[f.name] = f.numeric ? Number(v) : v; }
    const nested = action === 'late_damage' ? { damage: extra } : extra;
    const r = await fieldAct(action, { ...payload, ...nested });
    if (!r.ok) { setErr(r.message); return; }
    router.refresh();
  });
  return (
    <div className="fd-act">
      {fields?.map((f) => (
        <label key={f.name} className="field"><span className="label">{f.label}</span>
          {f.options ? <select className="select" value={vals[f.name]} onChange={(e) => setVals({ ...vals, [f.name]: e.target.value })}>{f.options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
            : <input className="input" inputMode={f.numeric ? 'numeric' : undefined} value={vals[f.name] ?? ''} onChange={(e) => setVals({ ...vals, [f.name]: e.target.value })} />}
        </label>))}
      <button className={`btn ${primary ? 'btn--primary' : 'btn--ghost'} fd-wide`} type="button" disabled={pending} onClick={run} data-testid={testId}>{pending ? 'Working' : label}</button>
      {err && <p className="error" role="alert">{err}</p>}
    </div>
  );
}
