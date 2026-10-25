'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { money } from '@/lib/format';
import { approveWithTerms, type ApproveCar } from '@/server/actions/owner-billing';
import { SOURCE_LABEL, dollars, hstOf, pctOf, toCents } from './shared';

// Approve, step "Terms and first invoice" (migration 0067): for each car the terms pre-filled from the negotiated
// defaults (or the grid), edited to the cent; then which invoices to make, each sent now, kept as a draft or recorded
// as already paid (e-Transfer, cash, cheque, bank transfer or another way). Nothing is sent before Approve.
type Terms = { insurance_fee_cents: number; tracker_fee_cents: number; revenue_share_bps: number; install_fee_cents: number; first_last_cents: number;
  sources: Record<string, string>; standard: Record<string, number>; one_off_fees: Array<{ description: string; amount_cents: number; hst: boolean }> };
export interface PlanCar { vehicle_id: string; name: string; onboarding_status: string; mode: string; method: string | null; shareholder: boolean;
  options: Array<{ method: string; label: string; recommended: boolean }>; terms: Terms; pending_terms: Record<string, unknown> | null;
  invoices: Array<{ invoice_number: string; status: string; total_cents: number; kind: string }> }
export interface Plan { id: string; application_number: string; status: string; trackers_available: boolean; today: string; entered_by_name: string | null; signing_method: string | null;
  plan: Record<string, { terms?: Record<string, number>; invoices?: Array<Record<string, unknown>> }> | null; cars: PlanCar[] }

export type Action = 'send' | 'draft' | 'paid' | 'none';
export interface Inv { on: boolean; amount: string; hst: boolean; action: Action; method: string; on_date: string; reference: string; paid: string; title: string }
interface CarState { mode: string; method: string; ins: string; trk: string; share: string; inst: string; fl: string; special: string; first_last: Inv; registration: Inv; tracker: Inv; custom: Inv & { desc: string } }
export const METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['cash', 'Cash'], ['cheque', 'Cheque'], ['bank_transfer', 'Bank transfer'], ['other', 'Other']];
export const inv = (today: string, on: boolean, amount: string, action: Action = 'send'): Inv => ({ on, amount, hst: true, action, method: 'e_transfer', on_date: today, reference: '', paid: '', title: '' });

function initial(c: PlanCar, today: string, proposed?: { terms?: Record<string, number>; invoices?: Array<Record<string, unknown>> }): CarState {
  const t = { ...c.terms, ...(proposed?.terms ?? {}) } as Terms;
  const fl = proposed?.terms?.first_last_cents ?? (proposed?.terms?.insurance_fee_cents ? proposed.terms.insurance_fee_cents * 2 : t.first_last_cents);
  const has = (type: string) => (proposed?.invoices ?? []).find((x) => x.type === type);
  const reg = c.terms.one_off_fees.find((f) => /registration/i.test(f.description));
  return {
    mode: c.mode, method: c.method ?? c.options.find((o) => o.recommended)?.method ?? c.options[0]?.method ?? '',
    ins: dollars(t.insurance_fee_cents), trk: dollars(t.tracker_fee_cents), share: pctOf(t.revenue_share_bps), inst: dollars(t.install_fee_cents), fl: dollars(fl), special: '',
    first_last: inv(today, !c.invoices.some((x) => x.kind === 'upfront'), dollars(fl), ((has('first_last')?.action as Action) ?? 'draft')),
    registration: { ...inv(today, !!(has('registration') || reg), dollars(Number(has('registration')?.amount_cents ?? reg?.amount_cents ?? 0) || null), (has('registration')?.action as Action) ?? 'send'), title: 'Registration fee' },
    tracker: inv(today, false, dollars(t.install_fee_cents)),
    custom: { ...inv(today, false, '', 'draft'), desc: '' }
  };
}

export function InvoiceChoice({ uid, label, v, set, hstBps, children, testId, allowNone = false }: { uid: string; label: string; v: Inv; set: (x: Inv) => void; hstBps: number; children?: React.ReactNode; testId: string; allowNone?: boolean }) {
  const net = toCents(v.amount);
  const total = Number.isFinite(net) ? net + (v.hst ? hstOf(net, hstBps) : 0) : 0;
  return (
    <fieldset className="stack ob-choice" data-testid={testId}>
      <legend className="vh">{label}</legend>
      <label className="check" htmlFor={`${uid}-on`}><input type="checkbox" id={`${uid}-on`} checked={v.on} onChange={(e) => set({ ...v, on: e.target.checked })} data-testid={`${testId}-on`} /><span><b>{label}</b></span></label>
      {v.on && (<>
        {children}
        {v.action !== 'none' && <div className="field-row">
          <div className="field"><label className="label" htmlFor={`${uid}-amt`}>Amount before HST ($)</label>
            <input className="input" id={`${uid}-amt`} inputMode="decimal" value={v.amount} onChange={(e) => set({ ...v, amount: e.target.value })} data-testid={`${testId}-amount`} /></div>
          <p className="small ob-choice__total">With HST: <b data-testid={`${testId}-total`}>{money(total, { cents: true })}</b></p>
        </div>}
        <div className="row ob-actions" role="radiogroup" aria-label={`${label}: what to do`} style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          {([['send', 'Send now'], ['draft', 'Save as draft'], ['paid', 'Already paid'], ...(allowNone ? [['none', 'No invoice']] : [])] as Array<[Action, string]>).map(([k, l]) => (
            <label key={k} className="check" htmlFor={`${uid}-a-${k}`}><input type="radio" id={`${uid}-a-${k}`} name={`${uid}-a`} checked={v.action === k} onChange={() => set({ ...v, action: k })} data-testid={`${testId}-${k}`} /><span>{l}</span></label>))}
        </div>
        {v.action === 'paid' && (
          <div className="field-row pt-sheet">
            <div className="field"><label className="label" htmlFor={`${uid}-m`}>Paid by</label>
              <select className="select" id={`${uid}-m`} value={v.method} onChange={(e) => set({ ...v, method: e.target.value })} data-testid={`${testId}-method`}>{METHODS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>
            <div className="field"><label className="label" htmlFor={`${uid}-d`}>Date received</label>
              <input className="input" type="date" id={`${uid}-d`} value={v.on_date} onChange={(e) => set({ ...v, on_date: e.target.value })} data-testid={`${testId}-date`} /></div>
            <div className="field"><label className="label" htmlFor={`${uid}-r`}>{v.method === 'cheque' ? 'Cheque number' : 'Reference'}{['cash', 'other'].includes(v.method) ? ' (optional)' : ''}</label>
              <input className="input" id={`${uid}-r`} value={v.reference} onChange={(e) => set({ ...v, reference: e.target.value })} data-testid={`${testId}-reference`} /></div>
            <div className="field"><label className="label" htmlFor={`${uid}-p`}>Amount received ($)</label>
              <input className="input" id={`${uid}-p`} inputMode="decimal" value={v.paid} placeholder={dollars(total)} onChange={(e) => set({ ...v, paid: e.target.value })} aria-describedby={`${uid}-p-h`} />
              <p className="hint" id={`${uid}-p-h`}>Empty: the full {money(total, { cents: true })}. Less is a partial payment.</p></div>
          </div>)}
      </>)}
    </fieldset>
  );
}

export function ApproveStep({ plan, owner, isTest, hstBps }: { plan: Plan; owner: string; isTest: boolean; hstBps: number }) {
  const router = useRouter();
  const a = useAct<{ invoices: Array<Record<string, unknown>>; note: string | null }>();
  const uid = `as-${useId().replace(/[^\w-]/g, '')}`;
  const cars = plan.cars.filter((c) => c.onboarding_status === 'intake');
  const [st, setSt] = useState<Record<string, CarState>>(() => Object.fromEntries(cars.map((c) => [c.vehicle_id, initial(c, plan.today, plan.plan?.[c.vehicle_id])])));
  const [problem, setProblem] = useState<string | null>(null);
  const upd = (id: string, patch: Partial<CarState>) => setSt({ ...st, [id]: { ...st[id]!, ...patch } });
  const payment = (v: Inv) => ({ method: v.method, received_on: v.on_date, reference: v.reference || undefined, amount_cents: v.paid ? toCents(v.paid) : undefined, note: v.method === 'other' ? v.reference : undefined });
  const build = (): ApproveCar[] | string => {
    const out: ApproveCar[] = [];
    for (const c of cars) {
      const s = st[c.vehicle_id]!;
      const n = { ins: toCents(s.ins), trk: toCents(s.trk), inst: toCents(s.inst), fl: toCents(s.fl), share: Math.round(Number(s.share) * 100) };
      if (!c.shareholder && [n.ins, n.trk, n.inst, n.fl, n.share].some((x) => !Number.isFinite(x) || x < 0)) return `${c.name}: enter every amount in dollars and cents.`;
      const invoices: Array<Record<string, unknown>> = [];
      const add = (type: string, v: Inv, extra: Record<string, unknown> = {}) => {
        if (!v.on) return null;
        const amt = toCents(v.amount);
        if (!Number.isFinite(amt) || amt <= 0) return `${c.name}: enter the amount of each invoice.`;
        if (v.action === 'paid' && ['e_transfer', 'cheque', 'bank_transfer'].includes(v.method) && v.reference.trim().length < 3) return `${c.name}: enter the reference of the payment.`;
        invoices.push({ type, amount_cents: amt, hst: v.hst, action: v.action, ...(v.action === 'paid' ? { payment: payment(v) } : {}), ...extra });
        return null;
      };
      // the first and last month: the Admin's choice for this car (0077); left unticked, nothing is invoiced and Today asks for it
      const firstLast = s.first_last.on && s.first_last.action === 'none' ? { action: 'none' } : undefined;
      const e1 = (firstLast ? null : add('first_last', s.first_last)) ?? add('registration', s.registration, { title: s.registration.title || 'Registration fee' })
        ?? (plan.trackers_available ? add('tracker_install', s.tracker) : null)
        ?? (s.custom.on ? (s.custom.desc.trim() ? add('custom', s.custom, { title: s.custom.title || undefined, lines: [{ description: s.custom.desc, quantity: 1, unit_amount_cents: toCents(s.custom.amount), hst: s.custom.hst }] }) : `${c.name}: describe the other invoice.`) : null);
      if (e1) return e1;
      if (s.first_last.on && !firstLast && toCents(s.first_last.amount) !== n.fl) return `${c.name}: the first and last invoice is ${money(toCents(s.first_last.amount), { cents: true })} but the terms say ${money(n.fl, { cents: true })}. Make them the same.`;
      out.push({ vehicle_id: c.vehicle_id, terms: c.shareholder ? { management_mode: s.mode, onboarding_method: s.method } : {
        management_mode: s.mode, onboarding_method: s.method || undefined, insurance_fee_cents: n.ins, tracker_fee_cents: n.trk, revenue_share_bps: n.share, install_fee_cents: n.inst,
        first_last_cents: n.fl, special_terms: s.special || undefined }, invoices, ...(firstLast ? { first_last: firstLast } : {}) });
    }
    return out;
  };
  const summary = cars.map((c) => { const s = st[c.vehicle_id]!; const parts = (['first_last', 'registration', 'tracker', 'custom'] as const).filter((k) => s[k].on).map((k) => `${k === 'first_last' ? 'first and last' : k === 'tracker' ? 'tracker install' : k === 'registration' ? 'registration fee' : 'other'} (${s[k].action === 'paid' ? 'paid' : s[k].action === 'draft' ? 'draft' : s[k].action === 'none' ? 'no invoice' : 'send'})`); return `${c.name}: ${parts.length ? parts.join(', ') : 'no invoice'}${s.first_last.on ? '' : ' (first and last month: decide later, on the Terms tab)'}`; }).join('; ');
  const submit = () => {
    setProblem(null);
    const cs = build();
    if (typeof cs === 'string') { setProblem(cs); return; }
    if (!window.confirm(`Approve ${owner}? ${summary}. Invoices marked "Send now" are emailed${plan.entered_by_name ? '; the owner gets the set-up email' : '; the owner gets the approval email'}.`)) return;
    a.run(() => approveWithTerms(plan.id, cs), (r) => { if (r.ok) router.refresh(); });
  };
  if (!cars.length) return <p className="small">No car is waiting for its terms.</p>;
  return (
    <form className="stack" noValidate aria-label="Terms and first invoice" data-testid="approve-step" onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <p className="small muted">Check each car&apos;s terms and choose the invoices. Nothing is set or sent until you press Approve{isTest ? ' (a test owner: staff emails stay with the test accounts)' : ''}.</p>
      {cars.filter((c) => !c.shareholder).length > 1 && (
        // 0135: one negotiation for several cars: the first car's numbers to every car, then change any car
        <div className="row"><button type="button" className="btn btn--ghost btn--sm" data-testid="approve-same-terms" onClick={() => {
          const first = cars.find((c) => !c.shareholder)!; const f = st[first.vehicle_id]!;
          setSt(Object.fromEntries(cars.map((c) => { const s = st[c.vehicle_id]!; return [c.vehicle_id, c.shareholder || c.vehicle_id === first.vehicle_id ? s
            : { ...s, mode: f.mode, ins: f.ins, trk: f.trk, share: f.share, inst: f.inst, fl: f.fl, first_last: { ...s.first_last, amount: f.fl } }]; })));
        }}>Use these terms for every car</button><span className="small muted">Copies {cars.find((c) => !c.shareholder)!.name}&apos;s numbers to the other cars.</span></div>)}
      {cars.map((c) => {
        const s = st[c.vehicle_id]!;
        const id = `${uid}-${c.vehicle_id.slice(0, 8)}`;
        const src = (k: string) => SOURCE_LABEL[c.terms.sources[k] ?? ''] ?? '';
        return (
          <section key={c.vehicle_id} className="pt-sheet stack" aria-label={c.name} data-testid="approve-car">
            <h3 className="d5">{c.name}</h3>
            {c.pending_terms && <p className="small ow-warn">An assistant proposed terms for this car. They are filled in below.</p>}
            {plan.plan?.[c.vehicle_id] && <p className="small muted">Filled in from what {plan.entered_by_name ?? 'staff'} entered.</p>}
            {!c.shareholder && (<>
              <div className="ad-fields ob-terms">
                <div className="field"><label className="label" htmlFor={`${id}-mode`}>Management Mode</label>
                  <select className="select" id={`${id}-mode`} value={s.mode} onChange={(e) => upd(c.vehicle_id, { mode: e.target.value, share: e.target.value === 'self_managed' ? '0' : s.share })}>
                    <option value="managed">Managed</option><option value="self_managed">Self-Managed</option><option value="turo_only">Turo-Only</option></select></div>
                {c.options.length > 0 && s.mode !== 'turo_only' && <div className="field"><label className="label" htmlFor={`${id}-meth`}>Onboarding Method</label>
                  <select className="select" id={`${id}-meth`} value={s.method} onChange={(e) => upd(c.vehicle_id, { method: e.target.value })}>{c.options.map((o) => <option key={o.method} value={o.method}>{o.label}{o.recommended ? ' (recommended)' : ''}</option>)}</select></div>}
                <div className="field"><label className="label" htmlFor={`${id}-ins`}>Insurance Fee a month ($)</label><input className="input" id={`${id}-ins`} inputMode="decimal" value={s.ins} data-testid="approve-insurance"
                  onChange={(e) => { const two = dollars(toCents(e.target.value) * 2); const keep = s.fl !== dollars(toCents(s.ins) * 2); upd(c.vehicle_id, { ins: e.target.value, ...(keep ? {} : { fl: two, first_last: { ...s.first_last, amount: two } }) }); }} />
                  <p className="hint">{src('insurance_fee_cents')}</p></div>
                <div className="field"><label className="label" htmlFor={`${id}-trk`}>Tracker Fee a month ($)</label><input className="input" id={`${id}-trk`} inputMode="decimal" value={s.trk} onChange={(e) => upd(c.vehicle_id, { trk: e.target.value })} data-testid="approve-tracker" /><p className="hint">{src('tracker_fee_cents')}</p></div>
                <div className="field"><label className="label" htmlFor={`${id}-share`}>Management fee (Revenue Share, %)</label><input className="input" id={`${id}-share`} inputMode="decimal" value={s.share} onChange={(e) => upd(c.vehicle_id, { share: e.target.value })} data-testid="approve-share" /><p className="hint">{src('revenue_share_bps')}</p></div>
                <div className="field"><label className="label" htmlFor={`${id}-inst`}>Install Fee ($)</label><input className="input" id={`${id}-inst`} inputMode="decimal" value={s.inst} onChange={(e) => upd(c.vehicle_id, { inst: e.target.value })} /><p className="hint">{src('install_fee_cents')}</p></div>
                <div className="field"><label className="label" htmlFor={`${id}-fl`}>First and last month amount ($)</label><input className="input" id={`${id}-fl`} inputMode="decimal" value={s.fl} data-testid="approve-first-last"
                  onChange={(e) => upd(c.vehicle_id, { fl: e.target.value, first_last: { ...s.first_last, amount: e.target.value } })} /><p className="hint">Default 2 x the Insurance Fee; any exact amount</p></div>
              </div>
              <div className="field"><label className="label" htmlFor={`${id}-sp`}>Special terms (optional)</label><input className="input" id={`${id}-sp`} value={s.special} onChange={(e) => upd(c.vehicle_id, { special: e.target.value })} /></div>
              {c.invoices.length > 0 && <p className="small">Already made for this car: {c.invoices.map((x) => `${x.invoice_number} (${money(x.total_cents, { cents: true })}, ${x.status})`).join(', ')}.</p>}
              {s.mode !== 'turo_only' && (<>
                <h4 className="label">First invoices</h4>
                <InvoiceChoice uid={`${id}-fl`} label="First and last month" v={s.first_last} hstBps={hstBps} testId="approve-inv-first-last" allowNone set={(x) => upd(c.vehicle_id, { first_last: x, fl: x.action === 'none' ? s.fl : x.amount })} />
                {!s.first_last.on && <p className="small muted" data-testid="approve-first-last-later">First and last month: nothing is invoiced until you decide (Admin &gt; Today asks for it).</p>}
                <InvoiceChoice uid={`${id}-rg`} label="Registration fee" v={s.registration} hstBps={hstBps} testId="approve-inv-registration" set={(x) => upd(c.vehicle_id, { registration: x })}>
                  <label className="check" htmlFor={`${id}-rg-hst`}><input type="checkbox" id={`${id}-rg-hst`} checked={s.registration.hst} onChange={(e) => upd(c.vehicle_id, { registration: { ...s.registration, hst: e.target.checked } })} /><span>Add HST</span></label>
                </InvoiceChoice>
                {plan.trackers_available
                  ? <InvoiceChoice uid={`${id}-tr`} label="Tracker install (its own invoice)" v={s.tracker} hstBps={hstBps} testId="approve-inv-tracker" set={(x) => upd(c.vehicle_id, { tracker: x })} />
                  : <p className="small muted">Tracker install: invoiced separately when trackers are available.</p>}
                <InvoiceChoice uid={`${id}-cu`} label="Another invoice" v={s.custom} hstBps={hstBps} testId="approve-inv-custom" set={(x) => upd(c.vehicle_id, { custom: { ...s.custom, ...x } })}>
                  <div className="field-row">
                    <div className="field"><label className="label" htmlFor={`${id}-cu-t`}>Title</label><input className="input" id={`${id}-cu-t`} value={s.custom.title} onChange={(e) => upd(c.vehicle_id, { custom: { ...s.custom, title: e.target.value } })} /></div>
                    <div className="field"><label className="label" htmlFor={`${id}-cu-d`}>What it is for</label><input className="input" id={`${id}-cu-d`} value={s.custom.desc} onChange={(e) => upd(c.vehicle_id, { custom: { ...s.custom, desc: e.target.value } })} data-testid="approve-inv-custom-desc" /></div>
                  </div>
                </InvoiceChoice>
              </>)}
            </>)}
          </section>
        );
      })}
      {problem && <p className="alert alert--error" role="alert" data-testid="approve-problem"><span>{problem}</span></p>}
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && a.res.data.note && <p className="alert alert--ok" role="status"><span>{a.res.data.note}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={a.pending} data-testid="approve-confirm">{a.pending ? 'Approving' : 'Approve'}</button></div>
    </form>
  );
}
