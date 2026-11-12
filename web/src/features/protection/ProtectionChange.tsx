'use client';
import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo } from '@/server/actions/offers';
import { CARD_ACK, OPCF_ACK, TITLE, changeText, label, planText, resultText, whatHappens, type Opt, type ProtectionOptions, type ProtectionResult } from './model';

// Change protection (2540, 2541), on the top card of the booking page in every portal that opens bookings (Admin, staff).
// One button, a small dialog: the three options with the price difference, the deposit, what the renter provides, the rule
// (card on the list, acknowledgements; an Admin may override with the reason), a required reason; it applies at once.
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });

export function ProtectionChange({ x, cards, proofUrl, admin }: { x: ProtectionOptions; cards: Array<{ id: string; label: string }>; proofUrl: string | null; admin: boolean }) {
  const router = useRouter();
  const ref = useRef<HTMLDialogElement>(null);
  const [to, setTo] = useState<Opt | null>(null);
  const [reason, setReason] = useState('');
  const [card, setCard] = useState(x.card?.id ?? '');
  const [cardAck, setCardAck] = useState(false);
  const [opcfAck, setOpcfAck] = useState(false);
  const [override, setOverride] = useState(false);
  const [notify, setNotify] = useState(true);
  const [note, setNote] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const req = x.request?.status === 'pending' ? x.request : null;
  const pick = x.options.find((o) => o.option === to) ?? null;
  const go = () => run(async () => {
    if (!to) return;
    setMsg(null);
    const r = await offersDo<ProtectionResult>('protection_change', { booking: x.booking_number, to, reason: reason.trim(), notify,
      ...(to === 2 && card ? { card } : {}), ...(to === 2 && cardAck ? { card_ack: true } : {}), ...(to === 1 && opcfAck ? { opcf27_ack: true } : {}), ...(override ? { override: true } : {}) });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: resultText(r.data) }); ref.current?.close(); setTo(null); setReason(''); router.refresh();
  });
  const review = (approve: boolean) => run(async () => {
    if (!req) return;
    const r = await offersDo<ProtectionResult>('protection_review', { request: req.id, approve, note: note.trim() || undefined });
    setMsg(r.ok ? { ok: true, text: approve ? resultText(r.data) : 'Declined: the renter sees the reason on their booking.' } : { ok: false, text: r.message });
    if (r.ok) { setNote(''); router.refresh(); }
  });
  return (
    <div className="stack" data-testid="protection">
      <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)', alignItems: 'center' }}>
        <span><span className="small muted">Damage to the car: </span><b data-testid="protection-now">{label(x.option_label)}</b>
          {x.open_cents > 0 && <span className="small muted"> · {fmt(x.open_cents)} open to collect</span>}</span>
        {x.may && <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setMsg(null); ref.current?.showModal(); }} data-testid="protection-open">Change protection</button>}
        {!x.may && x.why_not && <span className="small muted">{x.why_not}</span>}
      </div>
      {req && (
        <div className="alert alert--warn stack" role="note" data-testid="protection-request">
          <span className="alert__title">The renter asks to change to {req.to_label} ({when(req.created_at)})</span>
          <span>{req.reason ? `"${req.reason}". ` : ''}{req.to_option === 1 ? `Insurer ${req.insurer_name ?? ''}, policy ${req.policy_number ?? ''}, expires ${req.policy_expiry ?? ''}. ` : ''}
            {proofUrl ? <a className="link" href={proofUrl} target="_blank" rel="noopener" data-testid="protection-proof">Open the proof</a> : 'The proof is on file.'}</span>
          {x.may_review && <>
            <div className="field"><label className="label" htmlFor="pr-note">Note (needed to decline; the renter reads it)</label>
              <input className="input" id="pr-note" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} data-testid="protection-review-note" /></div>
            <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => review(true)} data-testid="protection-approve">Approve</button>
              <button className="btn btn--quiet btn--sm" type="button" disabled={pending || !note.trim()} onClick={() => review(false)} data-testid="protection-decline">Decline</button></div></>}
        </div>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="protection-msg"><span>{msg.text}</span></p>}

      <dialog ref={ref} className="pt-card" aria-labelledby="pr-h" data-testid="protection-dialog" style={{ maxWidth: 560, width: 'calc(100% - 32px)' }}>
        <div className="stack">
          <h2 className="d4" id="pr-h">Change protection</h2>
          <p className="small muted">How damage to the car is covered on {x.booking_number}. Deposit {fmt(x.deposit_cents)}: no coverage rule changes it.</p>
          <fieldset className="stack" style={{ border: 0, padding: 0 }}><legend className="vh">Choose the protection</legend>
            {x.options.map((o) => (
              <label key={o.option} className="option" data-testid={`protection-opt-${o.option}`}>
                <input type="radio" name="pr-to" value={o.option} disabled={o.current || !o.available} checked={to === o.option} onChange={() => { setTo(o.option); setOverride(false); }} />
                <span className="option__title">{TITLE[o.option]} <span className="small muted">{changeText(o)}</span></span>
                <span className="option__body">{o.option === 3 && x.plan_cents !== null ? `${planText(x)}. ` : ''}Renter provides: {o.needs}.{o.problem && !o.current ? ` ${o.problem}.` : ''}</span>
              </label>))}
          </fieldset>
          {pick && <p className="small" data-testid="protection-preview">{whatHappens(pick, x)} New total {fmt(pick.new_total_cents)}.</p>}
          {to === 2 && <div className="stack">
            <div className="field"><label className="label" htmlFor="pr-card">The renter&apos;s card (from the coverage list)</label>
              <select className="input" id="pr-card" value={card} onChange={(e) => setCard(e.target.value)} data-testid="protection-card">
                <option value="">Choose the card</option>{cards.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select></div>
            <label className="check"><input type="checkbox" checked={cardAck} onChange={(e) => setCardAck(e.target.checked)} data-testid="protection-card-ack" /> <span>The renter confirmed: {CARD_ACK}</span></label></div>}
          {to === 1 && <label className="check"><input type="checkbox" checked={opcfAck} onChange={(e) => setOpcfAck(e.target.checked)} data-testid="protection-opcf-ack" /> <span>The renter confirmed: {OPCF_ACK}</span></label>}
          {to && to !== 3 && admin && <label className="check"><input type="checkbox" checked={override} onChange={(e) => setOverride(e.target.checked)} data-testid="protection-override" />
            <span>Admin override: allow it without a covering card or the renter&apos;s confirmation (the reason is recorded)</span></label>}
          <div className="field"><label className="label" htmlFor="pr-reason">Reason (required; the renter reads it)</label>
            <input className="input" id="pr-reason" value={reason} maxLength={500} required onChange={(e) => setReason(e.target.value)} data-testid="protection-reason" /></div>
          <label className="check"><input type="checkbox" checked={notify} onChange={(e) => setNotify(e.target.checked)} /> <span>Tell the renter (one email, or the revised offer)</span></label>
          {msg && !msg.ok && <p className="alert alert--error" role="alert"><span>{msg.text}</span></p>}
          <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending || !to || reason.trim().length < 3} onClick={go} data-testid="protection-go">{pending ? 'Changing' : 'Change protection'}</button>
            <button className="btn btn--quiet btn--sm" type="button" onClick={() => ref.current?.close()}>Cancel</button></div>
          {x.history.length > 0 && <details><summary className="link small">Earlier changes ({x.history.length})</summary>
            <ul className="stack small">{x.history.map((h) => <li key={h.id}>{when(h.at)}: {h.from_label} to {h.to_label}, {fmt(h.total_before_cents)} to {fmt(h.total_after_cents)}{h.by ? `, by ${h.by}` : h.side === 'renter' ? ', by the renter' : ''}{h.note ? ` (${h.note})` : ''}</li>)}</ul></details>}
        </div>
      </dialog>
    </div>
  );
}
