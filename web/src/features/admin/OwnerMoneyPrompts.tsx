'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { guidedAct } from '@/server/actions/guided';
import type { Prompt, Terms } from '@/features/admin/todo/types';

// Two prompts of Admin > Today about owners (migration 0078): the first and last month an owner really paid after their
// invoices were voided (recorded as paid per car, so the two prepaid months count), and the terms agreed with an owner
// whose cars still run on the standard grid. Each also has its "Not needed" / "These are correct".
const today = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
const dollars = (c: number | string | null | undefined) => (c === null || c === undefined || c === '' ? '' : (Number(c) / 100).toFixed(2));
const cents = (s: string) => { const t = s.replace(/[$,\s]/g, ''); if (!t) return null; const n = Number(t); return Number.isFinite(n) ? Math.round(n * 100) : NaN; };
const METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['cash', 'Cash'], ['cheque', 'Cheque'], ['bank_transfer', 'Bank transfer'], ['other', 'Other']];

function Dismiss({ k, label, testId }: { k: string; label: string; testId: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  return (
    <>
      <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid={testId}
        onClick={() => start(async () => { const r = await guidedAct('todo_dismiss', { key: k }); if (r.ok) router.refresh(); else setMsg(r.message); })}>{pending ? 'Working' : label}</button>
      {msg && <span className="ad-err" role="alert">{msg}</span>}
    </>
  );
}

export function FirstLastPaid({ p }: { p: Prompt }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const cars = p.cars ?? [];
  const drafts = p.drafts ?? [];
  const [mode, setMode] = useState<'car' | 'total'>(cars.length > 1 ? 'car' : 'car');
  const [amt, setAmt] = useState<Record<string, string>>({});
  const [total, setTotal] = useState('');
  const [ticked, setTicked] = useState<string[]>(() => cars.map((c) => c.vehicle_id));
  const [method, setMethod] = useState('e_transfer');
  const [on, setOn] = useState(today);
  const [ref, setRef] = useState('');
  const [note, setNote] = useState('');
  const [keep, setKeep] = useState<Record<string, 'keep' | 'void'>>(() => Object.fromEntries(drafts.map((x) => [x.invoice_id, 'keep'])));
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const tid = `todo-act-${p.key}`;
  const submit = () => {
    const body: Record<string, unknown> = { owner_id: p.owner_id, method, received_on: on, reference: ref || null, note: note || null,
      drafts: Object.entries(keep).map(([invoice_id, action]) => ({ invoice_id, action })) };
    if (mode === 'total') {
      const t = cents(total);
      if (!t || Number.isNaN(t)) { setMsg('Enter the total paid.'); return; }
      body.total_cents = t; body.vehicle_ids = ticked;
    } else {
      const rows = cars.map((c) => ({ vehicle_id: c.vehicle_id, amount_cents: cents(amt[c.vehicle_id] ?? '') }));
      if (rows.some((r) => Number.isNaN(r.amount_cents))) { setMsg('Enter each amount in dollars, like 678 or 678.50.'); return; }
      body.cars = rows;
    }
    start(async () => {
      const r = await guidedAct('first_last_paid_record', body);
      if (!r.ok) { setMsg(r.message); return; }
      dlg.current?.close(); router.refresh();
    });
  };
  return (
    <span className="ad-actions">
      <button className="btn btn--primary btn--sm" type="button" aria-haspopup="dialog" data-testid={tid} onClick={() => { setMsg(null); dlg.current?.showModal(); }}>Record what they paid</button>
      <Dismiss k={p.key} label="Not needed" testId={`${tid}-dismiss`} />
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${idp}-t`} data-testid={`${tid}-dialog`}>
        <div className="gd-dialog__head"><h2 className="d4" id={`${idp}-t`}>First and last month paid by {p.owner}</h2>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button></div>
        <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }}>
          <p className="small">Type what they really paid, tax included. Each car gets its first and last month invoice marked paid, the owner gets the receipt, and the two prepaid months count on their monthly invoices.</p>
          <fieldset className="gd-cars"><legend className="pt-kicker">Amount</legend>
            <label className="check"><input type="radio" name={`${idp}-mode`} checked={mode === 'car'} onChange={() => setMode('car')} /> <span>Per car</span></label>
            <label className="check"><input type="radio" name={`${idp}-mode`} checked={mode === 'total'} onChange={() => setMode('total')} data-testid={`${tid}-total-mode`} /> <span>One total for several cars (split evenly)</span></label>
          </fieldset>
          {mode === 'car' ? (
            <div className="ad-fields">{cars.map((c) => (
              <div key={c.vehicle_id} className="field ad-field"><label className="label" htmlFor={`${idp}-${c.vehicle_id}`}>{c.name} ($)</label>
                <input className="input" id={`${idp}-${c.vehicle_id}`} inputMode="decimal" value={amt[c.vehicle_id] ?? ''} onChange={(e) => setAmt((s) => ({ ...s, [c.vehicle_id]: e.target.value }))}
                  aria-describedby={`${idp}-${c.vehicle_id}-h`} />
                <p className="hint" id={`${idp}-${c.vehicle_id}-h`}>{c.voided_cents ? `The voided invoice was $${dollars(c.voided_cents)}. ` : ''}Empty: nothing for this car.</p></div>))}
            </div>
          ) : (
            <div className="stack">
              <div className="field"><label className="label" htmlFor={`${idp}-total`}>Total paid ($)</label>
                <input className="input" id={`${idp}-total`} inputMode="decimal" value={total} onChange={(e) => setTotal(e.target.value)} data-testid={`${tid}-total`} /></div>
              <fieldset className="gd-cars"><legend className="pt-kicker">For these cars</legend>
                {cars.map((c) => <label key={c.vehicle_id} className="check"><input type="checkbox" checked={ticked.includes(c.vehicle_id)}
                  onChange={(e) => setTicked((s) => (e.target.checked ? [...s, c.vehicle_id] : s.filter((x) => x !== c.vehicle_id)))} /> <span>{c.name}</span></label>)}</fieldset>
            </div>
          )}
          <div className="ad-fields">
            <div className="field ad-field"><label className="label" htmlFor={`${idp}-m`}>Paid by</label>
              <select className="select" id={`${idp}-m`} value={method} onChange={(e) => setMethod(e.target.value)}>{METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
            <div className="field ad-field"><label className="label" htmlFor={`${idp}-on`}>Date received</label>
              <input className="input" id={`${idp}-on`} type="date" value={on} max={today()} onChange={(e) => setOn(e.target.value)} /></div>
            <div className="field ad-field"><label className="label" htmlFor={`${idp}-r`}>{method === 'cheque' ? 'Cheque number' : 'Reference'}</label>
              <input className="input" id={`${idp}-r`} value={ref} onChange={(e) => setRef(e.target.value)} /></div>
            <div className="field ad-field"><label className="label" htmlFor={`${idp}-n`}>Note (optional)</label>
              <input className="input" id={`${idp}-n`} value={note} onChange={(e) => setNote(e.target.value)} /></div>
          </div>
          {drafts.map((x) => (
            <fieldset key={x.invoice_id} className="gd-cars" data-testid={`${tid}-draft`}><legend className="pt-kicker">Draft {x.invoice_number} (${dollars(x.total_cents)})</legend>
              <label className="check"><input type="radio" name={`${idp}-${x.invoice_id}`} checked={keep[x.invoice_id] === 'keep'} onChange={() => setKeep((s) => ({ ...s, [x.invoice_id]: 'keep' }))} /> <span>Keep it (send or change it later)</span></label>
              <label className="check"><input type="radio" name={`${idp}-${x.invoice_id}`} checked={keep[x.invoice_id] === 'void'} onChange={() => setKeep((s) => ({ ...s, [x.invoice_id]: 'void' }))} data-testid={`${tid}-draft-void`} /> <span>Void it (replaced by what they paid)</span></label>
            </fieldset>))}
          {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid={`${tid}-submit`}>{pending ? 'Recording' : 'Record as paid'}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Cancel</button></div>
        </form>
      </dialog>
    </span>
  );
}

type TermFields = { share: string; ins: string; trk: string; inst: string; fl: string };
const fromTerms = (t?: Terms): TermFields => ({ share: t?.revenue_share_bps !== null && t?.revenue_share_bps !== undefined && t.revenue_share_bps !== '' ? String(Number(t.revenue_share_bps) / 100) : '',
  ins: dollars(t?.insurance_fee_cents), trk: dollars(t?.tracker_fee_cents), inst: dollars(t?.install_fee_cents), fl: dollars(t?.first_last_cents) });
const EMPTY: TermFields = { share: '', ins: '', trk: '', inst: '', fl: '' };
function toTerms(f: TermFields): Record<string, number | null> | string {
  const out: Record<string, number | null> = {};
  if (f.share.trim()) { const n = Number(f.share.replace('%', '')); if (!Number.isFinite(n) || n < 0 || n > 100) return 'The Management fee (Revenue Share) is a percentage from 0 to 100.'; out.revenue_share_bps = Math.round(n * 100); }
  for (const [k, v] of [['insurance_fee_cents', f.ins], ['tracker_fee_cents', f.trk], ['install_fee_cents', f.inst], ['first_last_cents', f.fl]] as const) {
    const c = cents(v); if (c !== null) { if (Number.isNaN(c) || c < 0) return 'Enter each fee in dollars, like 339 or 339.50.'; out[k] = c; }
  }
  return out;
}
function TermInputs({ f, set, idp, req }: { f: TermFields; set: (f: TermFields) => void; idp: string; req?: boolean }) {
  const row = (k: keyof TermFields, label: string, hint?: string) => (
    <div className="field ad-field"><label className="label" htmlFor={`${idp}-${k}`}>{label}</label>
      <input className="input" id={`${idp}-${k}`} inputMode="decimal" value={f[k]} onChange={(e) => set({ ...f, [k]: e.target.value })} required={req && k === 'share'} aria-describedby={hint ? `${idp}-${k}-h` : undefined} />
      {hint && <p className="hint" id={`${idp}-${k}-h`}>{hint}</p>}</div>);
  return (
    <div className="ad-fields">
      {row('share', 'Management fee (Revenue Share) (%)')}
      {row('ins', 'Insurance Fee, a month ($)')}
      {row('trk', 'Tracker Fee, a month ($)')}
      {row('inst', 'Install Fee ($)')}
      {row('fl', 'First and last month ($)', req ? 'Empty: two months of the Insurance Fee.' : undefined)}
    </div>
  );
}

export function TermsAgreed({ p }: { p: Prompt }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/[^\w-]/g, '');
  const cars = p.cars ?? [];
  const [f, setF] = useState<TermFields>(() => fromTerms(p.grid));
  const [own, setOwn] = useState<Record<string, TermFields>>({});
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const tid = `todo-act-${p.key}`;
  const submit = () => {
    const t = toTerms(f); if (typeof t === 'string') { setMsg(t); return; }
    const carRows: Array<{ vehicle_id: string; terms?: Record<string, number | null> }> = [];
    for (const c of cars) {
      const o = own[c.vehicle_id];
      if (o) { const ct = toTerms(o); if (typeof ct === 'string') { setMsg(`${c.name}: ${ct}`); return; } carRows.push({ vehicle_id: c.vehicle_id, terms: ct }); }
      else carRows.push({ vehicle_id: c.vehicle_id });
    }
    start(async () => {
      const r = await guidedAct<{ cars: Array<{ name: string; needs_resign: boolean }> }>('terms_agreed_save', { owner_id: p.owner_id, terms: t, cars: carRows });
      if (!r.ok) { setMsg(r.message); return; }
      dlg.current?.close(); router.refresh();
    });
  };
  return (
    <span className="ad-actions">
      <button className="btn btn--primary btn--sm" type="button" aria-haspopup="dialog" data-testid={tid} onClick={() => { setMsg(null); dlg.current?.showModal(); }}>Enter the terms</button>
      <Dismiss k={p.key} label="These are correct" testId={`${tid}-dismiss`} />
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${idp}-t`} data-testid={`${tid}-dialog`}>
        <div className="gd-dialog__head"><h2 className="d4" id={`${idp}-t`}>Terms agreed with {p.owner}</h2>
          <button className="btn btn--quiet btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button></div>
        <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }}>
          <p className="small">Filled in from the standard grid. Type what you agreed, to the cent. These become the owner&apos;s terms and every car&apos;s, unless a car has its own below.</p>
          <TermInputs f={f} set={setF} idp={`${idp}-o`} req />
          {cars.map((c) => (
            <details key={c.vehicle_id} className="gd-driver" open={!!own[c.vehicle_id]}>
              <summary className="small" onClick={(e) => { e.preventDefault(); setOwn((s) => { const n = { ...s }; if (n[c.vehicle_id]) delete n[c.vehicle_id]; else n[c.vehicle_id] = { ...EMPTY }; return n; }); }}>
                {own[c.vehicle_id] ? 'Same as above for' : 'Different terms for'} {c.name}{c.signed ? ' (schedule signed: an updated schedule goes to the owner to sign)' : ''}</summary>
              {own[c.vehicle_id] && <><p className="small muted">Empty fields: the owner&apos;s terms above.</p>
                <TermInputs f={own[c.vehicle_id]!} set={(x) => setOwn((s) => ({ ...s, [c.vehicle_id]: x }))} idp={`${idp}-${c.vehicle_id}`} /></>}
            </details>))}
          {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
          <div className="row"><button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid={`${tid}-submit`}>{pending ? 'Saving' : 'Save the terms'}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Cancel</button></div>
        </form>
      </dialog>
    </span>
  );
}
