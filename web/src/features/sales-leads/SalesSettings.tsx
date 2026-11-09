'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { leadAct } from '@/server/actions/sales-leads';
import { TYPE_LABEL, type LeadSettings, type LeadType } from './model';

/** Settings > Sales: how long a claim holds for each lead type, the most it can be extended to, the live claims a person may
 *  hold, and how long a lead counts as hot (the order of Next lead). */
export function SalesSettings({ s }: { s: LeadSettings }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const num = (name: string, label: string, value: number, min: number, max: number, hint: string) => (
    <div className="field" key={name}><label htmlFor={`ss-${name}`}>{label}</label>
      <input className="input" id={`ss-${name}`} name={name} type="number" min={min} max={max} defaultValue={value} required />
      <p className="small muted">{hint}</p></div>);
  return (
    <form className="pt-card ad-card stack" data-testid="sales-settings" onSubmit={(e) => {
      e.preventDefault();
      const p = Object.fromEntries([...new FormData(e.currentTarget)].map(([k, v]) => [k, Number(v)]));
      start(async () => { const r = await leadAct('sales_lead_settings_save', p); setMsg(r.ok ? { ok: true, text: 'Saved.' } : { ok: false, text: r.message }); if (r.ok) router.refresh(); });
    }}>
      <h2 className="d4">Lead claims</h2>
      <p className="small muted">Leads are never given out by themselves: they wait here for any onboarded salesperson to claim. A salesperson claims a lead and holds it for the minutes of its type; each call, text, email or note they log adds the same minutes again, up to the most. They can unclaim at any time; a claim that runs out returns the lead to the pool for everyone. An Admin can reassign or release any claim.</p>
      {(['renter', 'owner', 'partner'] as LeadType[]).map((k) => num(`${k}_minutes`, `${TYPE_LABEL[k]} leads: a claim holds (minutes)`, s.claim_minutes[k] ?? 15, 1, 240, '10 to 15 minutes suggested. 15 by default.'))}
      {num('extend_max_minutes', 'The most a claim can be extended to (minutes from the claim)', s.extend_max_minutes, 5, 480, '60 by default.')}
      {num('lead_cap_base', 'Open leads every salesperson may hold (not closed: won, lost or handled)', s.lead_cap_base ?? 3, 1, 500, '3 by default. At their cap, they close or unclaim one to take another.')}
      {num('lead_cap_per_wins', 'One more open lead for every (leads won in the last 30 days)', s.lead_cap_per_wins ?? 5, 1, 500, '5 by default. Only won counts.')}
      {num('lead_cap_max', 'The most open leads anyone may hold', s.lead_cap_max ?? 10, 1, 500, '10 by default.')}
      {num('claim_cooldown_minutes', 'One new claim every (minutes)', s.claim_cooldown_minutes ?? 5, 0, 120, '5 by default. 0: no pacing. Admins are not paced.')}
      {num('hot_hours', 'A lead is hot for (hours after it came in)', s.hot_hours, 1, 720, 'Next lead gives the oldest hot lead nobody holds first. 24 by default.')}
      <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid="sales-settings-save">Save</button>
      {s.updated_by && <p className="small muted">Last changed by {s.updated_by}.</p>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </form>
  );
}
