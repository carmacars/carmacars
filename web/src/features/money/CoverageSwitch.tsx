'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo } from '@/server/actions/offers';
import { cents } from '@/features/offers/model';
import { cardPreview, planPreview, resultText, type SwitchResult, type SwitchState } from './coverage-switch';

// Card coverage or the Protection Plan, on an offer or an active booking (migration 0890). The button shows what it will do
// (price, new total, what is cleared) before it is pressed; the database prices it, decides who may and refuses with the reason.
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });

export function CoverageSwitch({ x }: { x: SwitchState }) {
  const router = useRouter();
  const [open, setOpen] = useState<'plan' | 'card' | null>(null);
  const [note, setNote] = useState('');
  const [price, setPrice] = useState('');
  const [notify, setNotify] = useState(true);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const onPlan = x.option === 3;
  const go = (to: 'plan' | 'card') => run(async () => {
    setMsg(null);
    const planCents = to === 'plan' && price.trim() ? cents(price) : null;
    const r = await offersDo<SwitchResult>('coverage_switch', { booking: x.booking_number, to, note: note.trim() || undefined, notify, ...(planCents ? { plan_cents: planCents } : {}) });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: resultText(r.data) }); setOpen(null); setNote(''); setPrice(''); router.refresh();
  });
  if (!x.may && x.history.length === 0) return null;
  const target = onPlan ? 'card' : 'plan';
  const side = onPlan ? x.to_card : x.to_plan;
  return (
    <section className="pt-card ad-card stack" aria-labelledby="cs-h" data-testid="coverage-switch">
      <div className="pt-card__head"><h2 className="d4" id="cs-h">Coverage</h2></div>
      <p data-testid="cs-now"><b>{x.option_label.charAt(0).toUpperCase() + x.option_label.slice(1)}</b>{x.open_cents > 0 ? <span className="small muted"> · {fmt(x.open_cents)} open to collect</span> : null}</p>
      {x.may && !open && (side.available
        ? <p><button className="btn btn--ghost btn--sm" type="button" onClick={() => setOpen(target)} data-testid={`cs-to-${target}`}>
            {target === 'plan' ? 'Switch to the Protection Plan' : 'Switch to card coverage'}</button></p>
        : <p className="small muted" data-testid="cs-problem">{side.problem}</p>)}
      {!x.may && x.why_not && <p className="small muted">{x.why_not}</p>}
      {open && (
        <div className="stack" data-testid="cs-confirm">
          <p className="small" data-testid="cs-preview">{open === 'plan' ? planPreview(x) : cardPreview(x)}</p>
          {open === 'card' && <p className="small muted">The renter then confirms their card (or sends their policy) on their booking page; customer service reviews it as before.</p>}
          <div className="field"><label className="label" htmlFor="cs-note">Reason (the renter reads it)</label>
            <input className="input" id="cs-note" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} data-testid="cs-note" /></div>
          {open === 'plan' && !x.is_offer && <details><summary className="link small">Set the plan&apos;s price for this booking (customer service or an Admin)</summary>
            <div className="field"><label className="label" htmlFor="cs-price">Plan price before HST ($), for example for the days left</label>
              <input className="input input--sm" id="cs-price" inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} data-testid="cs-price" /></div></details>}
          <label className="check" htmlFor="cs-notify"><input id="cs-notify" type="checkbox" checked={notify} onChange={(e) => setNotify(e.target.checked)} /> <span>Email the renter what changed</span></label>
          <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => go(open)} data-testid="cs-go">{pending ? 'Switching' : open === 'plan' ? 'Switch to the Protection Plan' : 'Switch to card coverage'}</button>
            <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setOpen(null); setMsg(null); }}>Cancel</button></div>
        </div>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="cs-msg"><span>{msg.text}</span></p>}
      {x.history.length > 0 && <details data-testid="cs-history"><summary className="link small">Coverage switches ({x.history.length})</summary>
        <ul className="stack small">{x.history.map((h) => <li key={h.id}>{when(h.at)}: {h.from_label} to {h.to_label}, total {fmt(h.total_before_cents)} to {fmt(h.total_after_cents)}{h.by ? `, by ${h.by}` : ''}{h.note ? ` (${h.note})` : ''}, booking {h.status.replace(/_/g, ' ')}</li>)}</ul></details>}
    </section>
  );
}
