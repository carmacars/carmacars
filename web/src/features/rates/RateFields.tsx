'use client';
import { Fragment, useEffect, useRef, useState } from 'react';
import { money } from '@/lib/format';
import { rateCheck } from '@/server/actions/rates';
import { RATE_FIELDS, centsInput, ratePayload, ratesEmpty, type RateCheck, type RateValues } from './rates';

// The rates and the kilometre terms in one block (migration 0064): the four rates, labelled with their unit; the
// kilometres "Use the defaults" (Program settings and Fee defaults) or "Custom for this car"; the deposit (and on a
// car's Rates tab the delivery and pickup fees). Every change is checked by the database after a short pause: the
// errors show on their fields, and examples are priced with the same function as bookings.
export function RateFields({ v, set, context, prefix, delivery = false, optional = false, onCheck }: {
  v: RateValues; set: (k: string, value: string) => void;
  /** vehicle (an existing car) or class, make and model (Add a car) */
  context: Record<string, unknown>; prefix: string; delivery?: boolean; optional?: boolean; onCheck?: (c: RateCheck | null) => void;
}) {
  const [chk, setChk] = useState<RateCheck | null>(null);
  const [busy, setBusy] = useState(false);
  const seq = useRef(0);
  const key = JSON.stringify([ratePayload(v, { delivery }), context]);
  const empty = optional && ratesEmpty(v);
  useEffect(() => {
    if (empty) { setChk(null); onCheck?.(null); return; }
    const n = ++seq.current;
    setBusy(true);
    const t = setTimeout(async () => {
      const r = await rateCheck({ ...context, ...ratePayload(v, { delivery }) });
      if (n !== seq.current) return;
      setBusy(false);
      const c = r.ok ? r.data : null;
      setChk(c); onCheck?.(c);
    }, 350);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, empty]);
  const err = (k: string) => (empty ? undefined : chk?.errors?.[k]);
  const d = chk?.defaults;
  const id = (k: string) => `${prefix}-${k}`;
  const input = (k: string, label: string, o: { hint?: string; placeholder?: string; inputMode?: 'decimal' | 'numeric'; list?: string } = {}) => {
    const e = err(k);
    const desc = [o.hint ? `${id(k)}-h` : '', e ? `${id(k)}-e` : ''].filter(Boolean).join(' ') || undefined;
    return (
      <div className={`field ad-field${e ? ' has-error' : ''}`}>
        <label className="label" htmlFor={id(k)}>{label}</label>
        <input className="input" id={id(k)} inputMode={o.inputMode ?? 'decimal'} value={v[k] ?? ''} placeholder={o.placeholder} list={o.list}
          onChange={(x) => set(k, x.target.value)} aria-invalid={e ? true : undefined} aria-describedby={desc} data-testid={`${prefix}-${k}`} />
        {o.hint && <p className="hint" id={`${id(k)}-h`}>{o.hint}</p>}
        {e && <p className="error" id={`${id(k)}-e`} role="alert" data-testid={`${prefix}-${k}-error`}>{e}</p>}
      </div>);
  };
  const derivedPh = (k: string) => {
    const val = chk?.values?.[k];
    return chk && chk.derived?.includes(k) && typeof val === 'number' ? `Empty: ${money(val)}` : undefined;
  };
  const s = d?.suggestion;
  return (
    <div className="stack" data-testid={`${prefix}-rates`}>
      {s && <p className="small" data-testid={`${prefix}-suggestion`}>{s.text}{' '}
        <button className="btn btn--quiet btn--sm" type="button" data-testid={`${prefix}-use-suggestion`}
          onClick={() => { set('daily', centsInput(s.daily_cents)); set('weekend', centsInput(s.weekend_cents)); set('weekly', centsInput(s.weekly_cents)); set('monthly', centsInput(s.monthly_cents)); }}>Use these</button></p>}
      <div className="ad-fields">
        {RATE_FIELDS.map((f) => <Fragment key={f.key}>{input(f.key, `${f.label} ($)`, { hint: f.hint, placeholder: f.key === 'daily' ? undefined : derivedPh(f.key) })}</Fragment>)}
      </div>
      <fieldset className="stack" data-testid={`${prefix}-km`}>
        <legend className="label">Kilometres included and the extra kilometre rate</legend>
        <label className="check" htmlFor={id('km-default')}>
          <input type="radio" id={id('km-default')} name={id('km_mode')} checked={v.km_mode !== 'custom'} onChange={() => set('km_mode', 'default')} data-testid={`${prefix}-km-default`} />
          <span>Use the defaults{d ? `: ${d.km_per_day} km a day included, then ${d.overage_cents === null ? 'no default rate for this class' : money(d.overage_cents, { cents: true })} for each extra km` : ''}</span>
        </label>
        <label className="check" htmlFor={id('km-custom')}>
          <input type="radio" id={id('km-custom')} name={id('km_mode')} checked={v.km_mode === 'custom'} onChange={() => set('km_mode', 'custom')} data-testid={`${prefix}-km-custom`} />
          <span>Custom for this car</span>
        </label>
        {v.km_mode === 'custom' && (
          <div className="ad-fields">
            {input('km_per_day', 'Kilometres included a day', { inputMode: 'numeric', list: id('km-list'), placeholder: d ? String(d.km_per_day) : undefined,
              hint: d?.km_choices?.length ? `Usual choices: ${d.km_choices.join(', ')} km a day. A rental includes this times its days.` : 'A rental includes this times its days.' })}
            <datalist id={id('km-list')}>{(d?.km_choices ?? []).map((k) => <option key={k} value={k} />)}</datalist>
            {input('overage', 'Extra kilometre rate ($ a km)', { placeholder: d?.overage_cents != null ? centsInput(d.overage_cents) : undefined,
              hint: d?.overage_min_cents != null || d?.overage_max_cents != null ? `For this class: ${money(d?.overage_min_cents ?? 0, { cents: true })} to ${money(d?.overage_max_cents ?? 0, { cents: true })} a km.` : 'Charged at return for each km over what is included.' })}
          </div>)}
        {chk?.km_text && !empty && <p className="small muted" data-testid={`${prefix}-km-text`}>{chk.km_text}</p>}
      </fieldset>
      <div className="ad-fields">
        {input('deposit', 'Deposit ($, refundable, taken at pickup)', { list: id('dep-list'), placeholder: d?.deposit_cents != null && !v.deposit ? `Empty: ${money(d.deposit_cents)}` : undefined,
          hint: d?.deposit_tiers?.length ? `Tiers: ${d.deposit_tiers.map((t) => money(t.amount_cents)).join(', ')}, or any amount.` : undefined })}
        <datalist id={id('dep-list')}>{(d?.deposit_tiers ?? []).map((t) => <option key={t.amount_cents} value={centsInput(t.amount_cents)} />)}</datalist>
        {delivery && input('delivery', 'Delivery fee ($, 0: not offered)')}
        {delivery && input('pickup', 'Pickup fee ($, 0: not offered)')}
      </div>
      {!empty && (
        <div className="stack" aria-live="polite" data-testid={`${prefix}-preview`}>
          {busy && !chk && <p className="small muted">Checking the rates</p>}
          {chk && chk.examples.length > 0 && <div><p className="small"><b>What renters pay (before tax)</b></p>
            <ul className="small" data-testid={`${prefix}-examples`}>{chk.examples.map((x) => <li key={x.code} data-testid={`${prefix}-example-${x.code}`}>{x.text}</li>)}</ul></div>}
          {chk && chk.warnings.length > 0 && <p className="alert alert--warn" role="status" data-testid={`${prefix}-warnings`}><span>{chk.warnings.join(' ')}</span></p>}
        </div>)}
    </div>
  );
}

/** The fields' starting values from a rate card in force (or nothing). */
export function rateValuesFrom(card: Record<string, unknown> | null | undefined): RateValues {
  if (!card) return { km_mode: 'default' };
  return {
    daily: centsInput(card.daily_rate_cents), weekend: centsInput(card.weekend_rate_cents), weekly: centsInput(card.weekly_rate_cents), monthly: centsInput(card.monthly_rate_cents),
    km_mode: card.km_uses_defaults ? 'default' : 'custom', km_per_day: card.km_allowance_per_day != null ? String(card.km_allowance_per_day) : '',
    overage: centsInput(card.overage_cents_per_km), deposit: centsInput(card.deposit_cents), delivery: centsInput(card.delivery_fee_cents), pickup: centsInput(card.pickup_fee_cents)
  };
}
