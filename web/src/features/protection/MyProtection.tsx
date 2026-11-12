'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { changeProtection, protectionProofUpload } from '@/server/actions/portal';
import { toStandardImage } from '@/features/uploads/standard-image';
import { PHOTO_ACCEPT } from '@/features/uploads/formats';
import { TypedInput } from '@/components/DateInput';
import { CARD_ACK, OPCF_ACK, TITLE, changeText, label, planText, resultText, whatHappens, coverageChoiceProblem, type Opt, type ProtectionOptions, type ProtectionResult } from './model';

// "Change my protection" on the renter's booking page (2540, 2541), in the r40 portal's card language. The three ways
// damage to the car is covered, with their prices; the coverage order (a card on our list that covers the car and paying
// with it, else OPCF 27 and uploading the policy, else the Protection Plan); the database decides and refuses with the reason.
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const STATUS: Record<string, string> = { pending: 'Waiting for our review', approved: 'Approved', declined: 'Not approved', withdrawn: 'Withdrawn', superseded: 'Replaced by a later change' };

export function MyProtection({ number, x, cards }: { number: string; x: ProtectionOptions; cards: Array<{ id: string; label: string }> }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [to, setTo] = useState<Opt | null>(null);
  const [card, setCard] = useState(x.card?.id ?? '');
  const [cardAck, setCardAck] = useState(false);
  const [opcfAck, setOpcfAck] = useState(false);
  const [d, setD] = useState({ insurer_name: '', policy_number: '', policy_expiry: '' });
  const [ticket, setTicket] = useState('');
  const [busy, setBusy] = useState(false);
  const [reason, setReason] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const req = x.request;
  const waiting = req?.status === 'pending';
  const pick = x.options.find((o) => o.option === to) ?? null;
  const review = pick?.applies === 'review';
  // the rule the page can tell before sending (the card's own check is the database's, on send)
  const local = to ? coverageChoiceProblem(to, to === 2 ? (card ? { result: 'covered', card_id: card, message: '' } : null) : null, cardAck, opcfAck) : null;
  const ready = !!to && !local && (!review || (!!ticket && (to !== 1 || (d.insurer_name.trim() && d.policy_number.trim() && d.policy_expiry))));
  const upload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]; e.target.value = '';
    if (!file) return;
    setBusy(true); setMsg(null);
    try {
      const isPdf = file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf');
      const body: Blob = isPdf ? file : await toStandardImage(file);
      const t = await protectionProofUpload(number, isPdf ? 'application/pdf' : 'image/jpeg', body.size);
      if (!t.ok) throw new Error(t.message);
      const put = await fetch(t.data.url, { method: 'PUT', body, headers: t.data.headers });
      if (!put.ok) throw new Error('The upload did not finish. Try again.');
      setTicket(t.data.ticket);
    } catch (err) { setMsg({ ok: false, text: err instanceof Error ? err.message : 'The upload did not finish. Try again.' }); }
    finally { setBusy(false); }
  };
  const send = () => run(async () => {
    if (!to) return;
    setMsg(null);
    const r = await changeProtection(number, { to, reason: reason.trim() || undefined, card: to === 2 ? card : undefined, card_ack: to === 2 && cardAck, opcf27_ack: to === 1 && opcfAck,
      ...(review ? { ...(to === 1 ? d : {}), ticket } : {}) });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: resultText(r.data as ProtectionResult) }); setOpen(false); setTo(null); setTicket(''); router.refresh();
  });
  const withdraw = () => run(async () => {
    const r = await changeProtection(number, { withdraw: true });
    setMsg(r.ok ? { ok: true, text: 'Withdrawn: your protection stays as it is.' } : { ok: false, text: r.message });
    if (r.ok) router.refresh();
  });
  return (
    <div className="stack" id="protection" data-testid="my-protection">
      <p><span className="small muted">How damage to the car is covered: </span><b data-testid="my-protection-now">{label(x.option_label)}</b></p>
      {req && req.status !== 'superseded' && (
        <p className={`alert ${req.status === 'declined' ? 'alert--error' : req.status === 'pending' ? 'alert--warn' : 'alert--ok'}`} role="status" data-testid="my-protection-request">
          <span className="alert__title">Change to {req.to_label}: {STATUS[req.status] ?? req.status}</span>
          <span>{req.status === 'pending' ? 'Our team checks your proof, usually within 2 hours. The Protection Plan stays until then.' : req.decision_note ?? ''}</span></p>)}
      {waiting && <p><button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={withdraw} data-testid="my-protection-withdraw">Withdraw my request</button></p>}
      {!waiting && !open && <p><button className="btn btn--ghost btn--sm" type="button" onClick={() => { setOpen(true); setMsg(null); }} data-testid="my-protection-open">Change my protection</button></p>}
      {open && (
        <div className="stack" data-testid="my-protection-panel">
          <fieldset className="stack" style={{ border: 0, padding: 0 }}><legend className="label">Choose how the car is covered</legend>
            <p className="hint">In this order: your credit card if it is on our list and covers this car, else your own auto policy with OPCF 27, else the CarmaCars Protection Plan.</p>
            {x.options.map((o) => (
              <label key={o.option} className="option" data-testid={`my-protection-opt-${o.option}`}>
                <input type="radio" name="my-pr" value={o.option} disabled={o.current || !o.available} checked={to === o.option} onChange={() => setTo(o.option)} />
                <span className="option__title">{TITLE[o.option]} <span className="small muted">{changeText(o)}</span></span>
                <span className="option__body">{o.option === 3 && x.plan_cents !== null ? `${planText(x)}. ` : ''}You provide: {o.needs.replace(/the renter's/g, 'your').replace(/the renter/g, 'you')}.{!o.current && o.problem ? ` ${o.problem}.` : ''}</span>
              </label>))}
          </fieldset>
          {pick && <p className="small" data-testid="my-protection-preview">{whatHappens(pick, x)} New total {fmt(pick.new_total_cents)}.</p>}
          {to === 2 && <div className="stack">
            <div className="field"><label className="label" htmlFor="mp-card">Your credit card</label>
              <select className="input" id="mp-card" value={card} onChange={(e) => setCard(e.target.value)} data-testid="my-protection-card">
                <option value="">Choose your card</option>{cards.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select>
              <p className="hint">Not on the list? Then it cannot be used here: choose OPCF 27 or the Protection Plan. <a className="link" href="/credit-card-rental-coverage" target="_blank" rel="noopener">See the cards and their limits</a></p></div>
            <label className="check"><input type="checkbox" checked={cardAck} onChange={(e) => setCardAck(e.target.checked)} data-testid="my-protection-card-ack" /> <span>{CARD_ACK}</span></label></div>}
          {to === 1 && <label className="check"><input type="checkbox" checked={opcfAck} onChange={(e) => setOpcfAck(e.target.checked)} data-testid="my-protection-opcf-ack" /> <span>{OPCF_ACK}</span></label>}
          {review && <div className="stack">
            {to === 1 && <div className="field-row">
              <div className="field"><label className="label" htmlFor="mp-ins">Insurer</label><input className="input" id="mp-ins" maxLength={120} value={d.insurer_name} onChange={(e) => setD({ ...d, insurer_name: e.target.value })} /></div>
              <div className="field"><label className="label" htmlFor="mp-pol">Policy number</label><input className="input" id="mp-pol" maxLength={60} value={d.policy_number} onChange={(e) => setD({ ...d, policy_number: e.target.value })} /></div>
              <div className="field"><label className="label" htmlFor="mp-exp">Policy expiry</label><TypedInput className="input" id="mp-exp" type="date" value={d.policy_expiry} onChange={(e) => setD({ ...d, policy_expiry: e.target.value })} /></div></div>}
            <div className="field"><label className="btn btn--ghost btn--sm" htmlFor="mp-proof">{busy ? 'Uploading' : ticket ? 'Proof added: replace it' : to === 1 ? 'Add your policy (pink slip and OPCF 27 page)' : 'Add your card’s coverage letter'}</label>
              <input id="mp-proof" type="file" accept={`${PHOTO_ACCEPT},application/pdf`} onChange={upload} disabled={busy} className="vh" data-testid="my-protection-proof" /></div></div>}
          <div className="field"><label className="label" htmlFor="mp-reason">Anything we should know (optional)</label>
            <input className="input" id="mp-reason" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></div>
          {to && local && <p className="small muted" role="note">{local}</p>}
          <div className="row"><button className="btn btn--primary btn--sm" type="button" disabled={pending || busy || !ready} onClick={send} data-testid="my-protection-go">
            {pending ? 'Sending' : review ? 'Send for review' : pick && (pick.change_cents ?? 0) > 0 ? `Add it for ${fmt(pick.change_cents)}` : 'Change it'}</button>
            <button className="btn btn--quiet btn--sm" type="button" onClick={() => setOpen(false)}>Cancel</button></div>
        </div>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="my-protection-msg"><span>{msg.text}</span></p>}
    </div>
  );
}
