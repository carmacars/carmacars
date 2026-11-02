'use client';
import '@/styles/push.css';
import '@/styles/alerts.css';
import { useState, useTransition } from 'react';
import { saveAlertRule } from '@/server/actions/alerts';
import type { AlertRule } from './types';

// Alerts > Settings for the Admins (migration 0466): the one rule table behind every staff alert, by group. Each rule on
// or off, and its tier: urgent (phone at once, any hour), normal (phone, after the quiet hours), digest (in the app only).
const WHO: Record<string, string> = { admin: 'Admins', assigned: 'the person assigned', 'on_duty:cs': 'customer service on duty', 'on_duty:sales': 'Sales on duty',
  'on_duty:fleet': 'fleet on duty', 'unassigned_on_duty:cs': 'customer service on duty if nobody is assigned', 'unassigned_on_duty:sales': 'Sales on duty if nobody is assigned' };
const who = (w: string[]) => w.map((x) => WHO[x] ?? x.replace(/_/g, ' ')).join(', ');

export function AlertRules({ initial }: { initial: AlertRule[] }) {
  const [rules, setRules] = useState(initial);
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const groups = [...new Set(rules.map((r) => r.grp))];
  const change = (r: AlertRule, c: { enabled?: boolean; tier?: AlertRule['tier'] }) => {
    const was = rules;
    setRules((xs) => xs.map((x) => (x.rule === r.rule ? { ...x, ...c } : x))); setErr(null);
    start(async () => { const res = await saveAlertRule(r.rule, c); if (!res.ok) { setRules(was); setErr(res.message); } });
  };
  return (
    <section className="pt-card stack ar" id="rules" aria-labelledby="ar-title" data-testid="alert-rules">
      <h2 className="d4" id="ar-title">Which alerts staff get</h2>
      <p className="small muted">All on by default. Urgent: on the phone at once, at any hour. Normal: on the phone after the quiet hours. Digest: in Alerts only. Never to test accounts.</p>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      {groups.map((g) => {
        const rows = rules.filter((r) => r.grp === g);
        const on = rows.filter((r) => r.enabled).length;
        return (
          <details key={g} className="ar__group" data-testid="alert-rule-group">
            <summary><b>{g}</b> <span className="small muted">{on} of {rows.length} on</span></summary>
            <ul className="ar__list">
              {rows.map((r) => (
                <li key={r.rule} className="ar__row" data-testid={`alert-rule-${r.rule}`}>
                  <label className="option pa__opt ar__switch">
                    <input type="checkbox" role="switch" checked={r.enabled} disabled={pending} onChange={(e) => change(r, { enabled: e.target.checked })} aria-describedby={`ar-w-${r.rule}`} />
                    <span className="option__title">{r.label}</span>
                    <span className="option__body" id={`ar-w-${r.rule}`}>To {who(r.who)}.{r.hint ? ` ${r.hint}` : ''}</span>
                  </label>
                  <label className="ar__tier"><span className="vh">Tier of {r.label}</span>
                    <select className="input" value={r.tier} disabled={pending || r.fixed || !r.enabled} onChange={(e) => change(r, { tier: e.target.value as AlertRule['tier'] })}>
                      <option value="urgent">Urgent</option><option value="normal">Normal</option><option value="digest">Digest</option>
                    </select></label>
                </li>
              ))}
            </ul>
          </details>
        );
      })}
    </section>
  );
}
