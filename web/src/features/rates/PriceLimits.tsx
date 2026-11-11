'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { adminAct } from '@/server/actions/admin-portal';
import { saveOwnerPriceLimits } from '@/server/actions/owner';
import { limitsText, toCents, type Limits } from './price-limits';

// Price limits (1205): the lowest and highest daily rate a car is rented at, set by its owner (every car, or one car) and
// by an Admin. Lead-time pricing, promo codes, staff discounts and prices typed by staff never take a booking outside them
// unless an Admin allows it on the booking. Empty is no limit. The database checks the numbers again.
const dollars = (c: number | null | undefined) => (c === null || c === undefined ? '' : (c / 100).toFixed(2).replace(/\.00$/, ''));

export function PriceLimitsForm({ who, scope, vehicleId, ownerId, min, max, inherited, testId }: {
  who: 'owner' | 'admin'; scope: 'owner' | 'car'; vehicleId?: string; ownerId?: string; min: number | null; max: number | null;
  /** for a car: the owner's limits, used where the car has none */ inherited?: Limits | null; testId?: string;
}) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [lo, setLo] = useState(dollars(min));
  const [hi, setHi] = useState(dollars(max));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  function save(e: React.FormEvent) {
    e.preventDefault();
    const a = toCents(lo), b = toCents(hi);
    if (a === undefined || b === undefined) { setMsg({ ok: false, text: 'Type an amount in dollars, or leave it empty for no limit.' }); return; }
    if (a !== null && b !== null && a > b) { setMsg({ ok: false, text: 'The minimum is above the maximum.' }); return; }
    start(async () => {
      const p = { scope, vehicle_id: vehicleId ?? null, owner_id: ownerId ?? null, min_daily_cents: a, max_daily_cents: b };
      const r = who === 'admin' ? await adminAct('price_limits', p, vehicleId ? [`/admin/vehicles/${vehicleId}`] : []) : await saveOwnerPriceLimits(p);
      setMsg(r.ok ? { ok: true, text: 'Saved. New quotes and offers use it.' } : { ok: false, text: r.message });
      if (r.ok) router.refresh();
    });
  }
  const from = scope === 'car' && inherited ? limitsText(inherited) : null;
  return (
    <form onSubmit={save} className="stack pl" data-testid={testId ?? `price-limits-${scope}`} aria-label={scope === 'car' ? 'Price limits for this car' : 'Price limits for every car'}>
      <div className="row pl-row" style={{ gap: 'var(--s-3)', flexWrap: 'wrap' }}>
        <div className="field"><label className="label" htmlFor={`${idp}-min`}>Minimum a day ($)</label>
          <input className="input" id={`${idp}-min`} inputMode="decimal" value={lo} onChange={(e) => setLo(e.target.value)} placeholder="No minimum" data-testid="pl-min" /></div>
        <div className="field"><label className="label" htmlFor={`${idp}-max`}>Maximum a day ($)</label>
          <input className="input" id={`${idp}-max`} inputMode="decimal" value={hi} onChange={(e) => setHi(e.target.value)} placeholder="No maximum" data-testid="pl-max" /></div>
      </div>
      {from && <p className="small muted" data-testid="pl-inherited">Empty here: {who === 'owner' ? 'your' : 'the owner’s'} limits for every car apply ({from}).</p>}
      <p className="small muted">The rental after lead-time pricing, promo codes and discounts, divided by the days, stays between these. Fees, add-ons and tax are not counted. Empty is no limit.{who === 'admin' ? ' Allow a price outside them on one booking: the review screen, More options.' : ''}</p>
      <div className="row"><button type="submit" className="btn btn--primary btn--sm" disabled={pending} data-testid="pl-save">{pending ? 'Saving' : 'Save price limits'}</button>
        {msg && <span className={msg.ok ? 'small' : 'small ad-err'} role="status">{msg.text}</span>}</div>
    </form>
  );
}

/** Read only (Fleet's rates tab): the limits in force on a car and where they come from. */
export function PriceLimitsView({ limits }: { limits: Limits & { min_from?: string | null; max_from?: string | null } }) {
  const src = (s: string | null | undefined) => (s === 'car' ? 'this car' : s === 'owner' ? 'the owner, every car' : '');
  return (
    <dl className="kv" data-testid="price-limits-view">
      <div><dt>Minimum a day</dt><dd>{limits.min_daily_cents !== null ? <>{money(limits.min_daily_cents)} <span className="small muted">({src(limits.min_from)})</span></> : 'No minimum'}</dd></div>
      <div><dt>Maximum a day</dt><dd>{limits.max_daily_cents !== null ? <>{money(limits.max_daily_cents)} <span className="small muted">({src(limits.max_from)})</span></> : 'No maximum'}</dd></div>
    </dl>
  );
}
