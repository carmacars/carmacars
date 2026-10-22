'use client';
import './live.css';
import Link from 'next/link';
import { useState } from 'react';
import { ACTION_WORDS, GROUP_WORDS, liveDo, type SignalAction, type SignalConfig, type SignalRule, type SignalSettingsData } from './staff';

// Admin > Live visitors > Signal settings (migration 0086): every signal's points towards the booking likelihood, its
// thresholds, the suggested action and message, the score bands, the hot alert and the discount code staff may send.
// Saved at once; the next look at a visit uses them.
const GROUPS = ['intent', 'urgency', 'value', 'hesitation', 'context'];
const ACTIONS: SignalAction[] = ['chat', 'discount', 'assign', 'similar', 'none'];
type Edit = Partial<Pick<SignalRule, 'enabled' | 'weight' | 't1' | 't2' | 'param' | 'label' | 'action' | 'message'>>;

export function SignalSettings({ initial }: { initial: SignalSettingsData }) {
  const [rules, setRules] = useState(initial.rules);
  const [edits, setEdits] = useState<Record<string, Edit>>({});
  const [cfg, setCfg] = useState<SignalConfig>(initial.config);
  const [msg, setMsg] = useState('');
  const [cmsg, setCmsg] = useState('');
  const can = initial.can_edit;
  const set = (code: string, e: Edit) => { setRules((rs) => rs.map((r) => (r.code === code ? { ...r, ...e } : r))); setEdits((x) => ({ ...x, [code]: { ...x[code], ...e } })); };
  const saveRules = async () => {
    const list = Object.entries(edits).map(([code, e]) => ({ code, ...e }));
    if (!list.length) { setMsg('Nothing changed.'); return; }
    try { const r = await liveDo<{ saved: number }>('live_rules_save', { rules: list }); setEdits({}); setMsg(`Saved ${r.saved} signal${r.saved === 1 ? '' : 's'}. The next look at each visit uses them.`); }
    catch (e) { setMsg(e instanceof Error ? e.message : 'That did not work'); }
  };
  const saveCfg = async () => {
    try { await liveDo('live_config_save', { ...cfg, discount_max_cents: cfg.discount_max_cents ?? '' }); setCmsg('Saved.'); }
    catch (e) { setCmsg(e instanceof Error ? e.message : 'That did not work'); }
  };
  const w = initial.week;
  return (
    <div className="lv stack" data-testid="signal-settings">
      <p className="small"><Link prefetch={false} className="link" href="/admin/live">Back to Live visitors</Link></p>
      <div className="ad-tiles">
        <div className="ad-tile"><span className="ad-tile__k">Hot visits, 7 days</span><b className="ad-tile__v">{w.hot}</b></div>
        <div className="ad-tile"><span className="ad-tile__k">Actions taken, 7 days</span><b className="ad-tile__v">{w.acted}</b></div>
        <div className="ad-tile"><span className="ad-tile__k">Discount codes sent, 7 days</span><b className="ad-tile__v">{w.discounts}</b><span className="ad-tile__s">{w.discounts_used} used in 30 days</span></div>
      </div>
      {!can && <p className="pt-note" role="status">Only an Admin changes these settings.</p>}

      <section className="pt-card ad-card" aria-labelledby="ss-score">
        <div className="pt-card__head"><h2 className="d4" id="ss-score">Score and actions</h2></div>
        <p className="small muted">The booking likelihood of a visit is the sum of the points of its signals, from 0 to 100. A signal is strong or medium from the points below.</p>
        <fieldset className="ss-grid" disabled={!can}>
          <legend className="vh">Score and actions</legend>
          <NumField id="ss-hot" label="Hot from" value={cfg.hot_score} onChange={(v) => setCfg({ ...cfg, hot_score: v ?? 0 })} />
          <NumField id="ss-warm" label="Warm from" value={cfg.warm_score} onChange={(v) => setCfg({ ...cfg, warm_score: v ?? 0 })} />
          <NumField id="ss-strong" label="Strong signal from (points)" value={cfg.strong_weight} onChange={(v) => setCfg({ ...cfg, strong_weight: v ?? 0 })} />
          <NumField id="ss-medium" label="Medium signal from (points)" value={cfg.medium_weight} onChange={(v) => setCfg({ ...cfg, medium_weight: v ?? 0 })} />
          <label className="check small"><input type="checkbox" checked={cfg.notify_hot} onChange={(e) => setCfg({ ...cfg, notify_hot: e.target.checked })} /><span>Alert staff on Live visitors when a visitor turns hot (in the page; on the desktop only for those who turned on desktop alerts in Live chat, and never in the site check&apos;s quiet hours)</span></label>
          <label className="check small"><input type="checkbox" checked={cfg.discount_enabled} onChange={(e) => setCfg({ ...cfg, discount_enabled: e.target.checked })} /><span>Staff may send a discount code from Live visitors</span></label>
          <NumField id="ss-pct" label="Discount (%)" value={cfg.discount_percent} onChange={(v) => setCfg({ ...cfg, discount_percent: v ?? 0 })} />
          <NumField id="ss-cap" label="At most off a booking ($)" value={cfg.discount_max_cents === null ? null : cfg.discount_max_cents / 100} onChange={(v) => setCfg({ ...cfg, discount_max_cents: v === null ? null : Math.round(v * 100) })} />
          <NumField id="ss-days" label="Valid for (days)" value={cfg.discount_valid_days} onChange={(v) => setCfg({ ...cfg, discount_valid_days: v ?? 1 })} />
          <NumField id="ss-daily" label="Codes a day per person" value={cfg.discount_daily_cap} onChange={(v) => setCfg({ ...cfg, discount_daily_cap: v ?? 0 })} />
          <label className="check small"><input type="checkbox" checked={cfg.discount_cs} onChange={(e) => setCfg({ ...cfg, discount_cs: e.target.checked })} /><span>Customer service may send codes too (Admins and Sales always may)</span></label>
          <div className="field ss-wide"><label className="label" htmlFor="ss-dmsg">Discount message ({'{code}'}, {'{percent}'}, {'{valid_until}'} and {'{first_name_sp}'} are filled in)</label>
            <textarea id="ss-dmsg" className="input" rows={2} maxLength={600} value={cfg.discount_message} onChange={(e) => setCfg({ ...cfg, discount_message: e.target.value })} /></div>
        </fieldset>
        {can && <p><button type="button" className="btn btn--primary btn--sm" onClick={() => void saveCfg()}>Save score and actions</button> <span className="small" role="status">{cmsg}</span></p>}
      </section>

      {GROUPS.map((g) => (
        <section key={g} className="pt-card ad-card" aria-labelledby={`ss-${g}`} data-testid={`rules-${g}`}>
          <div className="pt-card__head"><h2 className="d4" id={`ss-${g}`}>{GROUP_WORDS[g]}</h2></div>
          <ul className="ss-rules">{rules.filter((r) => r.grp === g).map((r) => (
            <li key={r.code} className="ss-rule" data-testid="rule">
              <fieldset disabled={!can}>
                <legend className="vh">{r.label}</legend>
                <div className="ss-rule__top">
                  <label className="check"><input type="checkbox" checked={r.enabled} onChange={(e) => set(r.code, { enabled: e.target.checked })} aria-label={`${r.label}: on`} /><b>{r.label}</b></label>
                  <NumField id={`w-${r.code}`} label="Points" value={r.weight} onChange={(v) => set(r.code, { weight: v ?? 0 })} />
                </div>
                <p className="small muted">{r.explain}</p>
                <div className="ss-grid">
                  {r.t1_label && <NumField id={`t1-${r.code}`} label={r.t1_label} value={r.t1} onChange={(v) => set(r.code, { t1: v })} />}
                  {r.t2_label && <NumField id={`t2-${r.code}`} label={r.t2_label} value={r.t2} onChange={(v) => set(r.code, { t2: v })} />}
                  {r.param_label && <div className="field ss-wide"><label className="label" htmlFor={`p-${r.code}`}>{r.param_label} (separated by commas)</label>
                    <textarea id={`p-${r.code}`} className="input" rows={2} value={r.param ?? ''} onChange={(e) => set(r.code, { param: e.target.value })} /></div>}
                  <div className="field"><label className="label" htmlFor={`a-${r.code}`}>Suggested action</label>
                    <select id={`a-${r.code}`} className="select" value={r.action} onChange={(e) => set(r.code, { action: e.target.value as SignalAction })}>
                      {ACTIONS.map((a) => <option key={a} value={a}>{ACTION_WORDS[a]}</option>)}</select></div>
                  <div className="field ss-wide"><label className="label" htmlFor={`m-${r.code}`}>Message to suggest</label>
                    <textarea id={`m-${r.code}`} className="input" rows={2} maxLength={600} value={r.message} onChange={(e) => set(r.code, { message: e.target.value })} /></div>
                </div>
              </fieldset>
            </li>))}</ul>
        </section>))}
      {can && <p className="ss-save"><button type="button" className="btn btn--primary" onClick={() => void saveRules()} data-testid="save-rules">Save the signals</button> <span className="small" role="status">{msg}</span></p>}
      <p className="small muted">In messages, {'{car}'}, {'{other}'}, {'{days}'}, {'{pickup}'}, {'{booking}'}, {'{topics}'}, {'{similar}'}, {'{first_name_sp}'} and {'{staff}'} are filled in from the visit. The first six signals (offer opened, change proposal, pay page left, request stopped, returning visitor, viewing spree) keep their thresholds in Program settings, group &quot;Live visitors and live chat&quot;.</p>
    </div>
  );
}

function NumField({ id, label, value, onChange }: { id: string; label: string; value: number | null; onChange: (v: number | null) => void }) {
  return (
    <div className="field ss-num"><label className="label" htmlFor={id}>{label}</label>
      <input id={id} className="input" type="number" inputMode="decimal" value={value ?? ''} onChange={(e) => onChange(e.target.value === '' ? null : Number(e.target.value))} /></div>
  );
}
