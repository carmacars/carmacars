'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import '@/styles/late-return.css';
import { LATE_KEYS, LATE_LABEL, NO_CHOICE, choiceAmount, choiceNeedsAdmin, choicePayload, choiceProblem, decisionText, optionDetail, type LateChoice, type LateReturn } from './late-return';

// The late return choice (migration 2660): five big choices, each with what it costs now. On the return screen it is part
// of the checklist (the choice travels with the return; "Decide later" leaves a To do); on the booking it has its own
// button. Nothing is charged for a late return until someone chooses here.
const fmt = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export function LateReturnChoice({ late, value, onChange, later = false, name = 'late' }: { late: LateReturn; value: LateChoice; onChange: (c: LateChoice) => void;
  /** the return screen: "Decide later" is a choice too */ later?: boolean; name?: string }) {
  const amount = choiceAmount(value, late);
  const problem = choiceProblem(value, late);
  return (
    <fieldset className="lr-choices" data-testid="late-choice">
      <legend className="label">How is the late return charged?</legend>
      {later && <label className="lr-choice"><input type="radio" name={name} checked={value.option === ''} onChange={() => onChange(NO_CHOICE)} data-testid="late-later" />
        <span><b>Decide later</b><span className="small">The office chooses on the booking. Nothing is charged until then.</span></span></label>}
      {LATE_KEYS.map((k) => (
        <label key={k} className="lr-choice"><input type="radio" name={name} checked={value.option === k} onChange={() => onChange({ ...value, option: k })} data-testid={`late-${k}`} />
          <span><b>{LATE_LABEL[k]}</b><span className="small">{optionDetail(k, late)}</span></span></label>
      ))}
      {value.option === 'extra_days' && <label className="field"><span className="label">Extra days</span>
        <input className="input" inputMode="numeric" pattern="[0-9]*" value={value.days} placeholder={String(late.options.find((o) => o.key === 'extra_days')?.days ?? 1)}
          onChange={(e) => onChange({ ...value, days: e.target.value.replace(/\D/g, '') })} data-testid="late-days" /></label>}
      {value.option === 'custom' && <label className="field"><span className="label">Amount before tax ($)</span>
        <input className="input" inputMode="decimal" value={value.amount} onChange={(e) => onChange({ ...value, amount: e.target.value.replace(/[^\d.]/g, '') })} data-testid="late-amount" /></label>}
      {(value.option === 'custom' || value.option === 'waive') && <label className="field"><span className="label">{value.option === 'waive' ? 'Why it is waived' : 'What it is for (the renter sees it)'}</span>
        <input className="input" maxLength={300} value={value.reason} onChange={(e) => onChange({ ...value, reason: e.target.value })} data-testid="late-reason" /></label>}
      {value.option !== '' && <p className="small" role="status" data-testid="late-summary">
        {problem ?? (value.option === 'waive' ? 'No charge for the late return.' : `${fmt(amount ?? 0)} plus tax goes on the return statement. It is taken from the deposit, or from the card on file if the deposit does not cover it.`)}
        {!problem && choiceNeedsAdmin(value, late) ? ' This one waits for an Admin before it counts.' : ''}{!problem ? ' The renter gets a message that says so.' : ''}</p>}
    </fieldset>
  );
}

/** On the booking: the choice with its button, or where the decision stands. */
export function LateReturnDecide({ late, refresh = [] }: { late: LateReturn; refresh?: string[] }) {
  const router = useRouter();
  const [c, setC] = useState<LateChoice>(NO_CHOICE);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const d = late.decision;
  const send = (p: Record<string, unknown>) => start(async () => {
    setMsg(null);
    const r = await opsAct<{ status: string; renter_told?: boolean }>('late_return_decide', { booking: late.booking_id, ...p }, refresh);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setMsg({ ok: true, text: r.data.status === 'needs_admin' ? 'Saved. It waits for an Admin: they have a To do.' : `Saved.${r.data.renter_told ? ' The renter has a message about it.' : ''}` });
    setC(NO_CHOICE); router.refresh();
  });
  const go = () => { const p = choicePayload(c, late); if (!p) { setMsg({ ok: false, text: choiceProblem(c, late) ?? 'Choose how the late return is charged.' }); return; } send(p); };
  const open = !late.locked && late.may.decide && (!d || d.status === 'pending' || (late.may.admin && d.status !== 'pending'));
  return (
    <div className="stack" data-testid="late-return">
      <p className="ad-late" data-testid="late-return-facts"><b>Late by {late.late_text}.</b> {d ? decisionText(d) : 'No late return charge is chosen yet. Nothing is charged until someone chooses.'}</p>
      {late.locked && <p className="small muted">The late return charge is on a statement or paid: credit or refund it from Money instead.</p>}
      {d?.status === 'needs_admin' && late.may.admin && !late.locked &&
        <p><button className="btn btn--primary" type="button" disabled={pending} onClick={() => send({ approve: true })} data-testid="late-approve">{pending ? 'Working' : 'Approve as asked'}</button></p>}
      {open && (d && d.status !== 'pending'
        ? <details><summary className="small link" data-testid="late-change">{d.status === 'needs_admin' ? 'Choose another way instead' : 'Admin: change the late return charge'}</summary>
            <LateReturnChoice late={late} value={c} onChange={setC} name="late-booking" />
            <button className="btn btn--primary" type="button" disabled={pending || !c.option} onClick={go} data-testid="late-save">{pending ? 'Working' : 'Save the late return charge'}</button></details>
        : <><LateReturnChoice late={late} value={c} onChange={setC} name="late-booking" />
            <button className="btn btn--primary" type="button" disabled={pending || !c.option} onClick={go} data-testid="late-save">{pending ? 'Working' : 'Save the late return charge'}</button></>)}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'} data-testid="late-message"><span>{msg.text}</span></p>}
    </div>
  );
}
