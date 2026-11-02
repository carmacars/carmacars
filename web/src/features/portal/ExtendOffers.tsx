'use client';
import { useState, type ReactNode } from 'react';
import { useRouter } from 'next/navigation';
import { extendWithOption, extensionPayLink, type ExtendOutcome } from '@/server/actions/portal';
import { minutesToClock, shortDate, torontoParts } from '@/lib/dates';
import { money } from '@/lib/format';
import { useAct } from './useAct';
import './extend.css';

// Extend (0480): the six offers of public.my_extension_offers, each with its new return, price, the regular price struck
// through and the saving; unavailable ones disabled with the reason. One tap pays with the Card on File when the
// database approves it at once (or opens the pay page, 0482, when there is none), else it is a request for our team.
// Every number comes from the database.
export interface ExtOption {
  code: string; label: string; new_return_at: string; available: boolean; reason: string | null; pricing: string | null; fallback_to: string | null;
  total_cents: number | null; regular_total_cents: number | null; save_cents: number | null; save_pct: number; late_cost_cents: number | null; hours: number; days: number;
}
export interface ExtOffers {
  booking_number: string; return_at: string; offers: boolean; message: string | null; options: ExtOption[];
  discount_bps: number; short_discount_bps: number; available_until: string | null; available_until_text: string | null;
  late: { minutes: number; owed_cents: number } | null; card: { brand: string; last4: string } | null;
}

export const at = (iso: string) => { const p = torontoParts(iso); return `${shortDate(p.date)}, ${minutesToClock(p.minutes)}`; };
const $ = (c: number | null | undefined) => money(c ?? 0, { cents: true });
const brand = (b: string) => (b ? b.charAt(0).toUpperCase() + b.slice(1) : 'Card');
const late = (m: number) => (m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m} minutes`);

export function ExtendOffers({ data, children }: { data: ExtOffers; children?: ReactNode }) {
  const router = useRouter();
  // a few hours that would cost more than a day are not shown: the day is the better price
  const shown = data.options.filter((o) => !o.fallback_to);
  const cheaperThan = data.options.filter((o) => o.fallback_to).map((o) => o.label);
  const first = shown.find((o) => o.available)?.code ?? '';
  const [pick, setPick] = useState(first);
  const go = useAct<ExtendOutcome>();
  const link = useAct<{ url: string }>();
  const o = shown.find((x) => x.code === pick);
  const done = go.res?.ok ? go.res.data : null;

  if (done && (done.state === 'paid' || done.state === 'requested')) return (
    <div className="ext-done" role="status" data-testid="extend-done">
      <p className="ext-done__kicker">{done.state === 'paid' ? 'Extended' : 'Request sent'}</p>
      <p className="ext-done__when">{at(done.newReturnAt)}</p>
      <p className="small">{done.state === 'paid'
        ? `Paid ${$(done.totalCents)}. Your new return time is confirmed, and the reminders follow it.`
        : 'Our team checks the calendar and confirms shortly. Once approved, you pay here. Until then your return time stays as it was.'}</p>
      <a className="btn btn--primary" href={`/account/bookings/${encodeURIComponent(data.booking_number)}`}>Back to the booking</a>
    </div>
  );

  return (
    <div className="ext">
      {data.late && data.late.minutes > 0 && (
        <p className="alert alert--warn" role="alert" data-testid="extend-late">
          <span className="alert__title">You are {late(data.late.minutes)} past your return time</span>
          <span>Late charges so far: {$(data.late.owed_cents)} before HST. They stay owed until an extension is paid. Each option below counts from your original return time.</span>
        </p>
      )}
      <fieldset className="ext__set">
        <legend className="vh">How much longer do you need?</legend>
        {data.available_until_text && <p className="small muted ext__until" data-testid="extend-until">{data.available_until_text}</p>}
        <div className="ext__grid">
          {shown.map((x) => {
            const id = `ext-${x.code}`;
            const save = x.available && x.save_pct > 0 && (x.regular_total_cents ?? 0) > (x.total_cents ?? 0);
            return (
              <label key={x.code} htmlFor={id} className="ext__opt" data-on={pick === x.code || undefined} data-off={!x.available || undefined} data-testid={`extend-opt-${x.code}`}>
                <input type="radio" id={id} name="ext-option" value={x.code} checked={pick === x.code} disabled={!x.available || go.pending} onChange={() => setPick(x.code)} />
                <span className="ext__label">{x.label}</span>
                <span className="ext__ret">Until {at(x.new_return_at)}</span>
                {x.available ? (
                  <span className="ext__price">
                    <b>{$(x.total_cents)}</b>
                    {save && <s aria-label={`Regular price ${$(x.regular_total_cents)}`}>{$(x.regular_total_cents)}</s>}
                  </span>
                ) : <span className="ext__reason">{x.reason}</span>}
                {save && <span className="ext__save">You save {x.save_pct}%</span>}
                {x.available && x.code === '1d' && cheaperThan.length > 0 && <span className="ext__note">Costs less than {cheaperThan.join(' or ')} of late fees</span>}
              </label>
            );
          })}
        </div>
      </fieldset>
      {o?.available && o.late_cost_cents ? (
        <p className="small ext__compare" data-testid="extend-compare">Being {o.label} late would cost {$(o.late_cost_cents)} (the late fee and an extra day of rental).</p>
      ) : null}
      {go.res && !go.res.ok && <p className="alert alert--error" role="alert"><span>{go.res.message}</span></p>}
      {done?.state === 'link' && <p className="small" role="status">Approved. Opening the secure payment page.</p>}
      {done?.state === 'approved' && (
        <div className="ext__pay" data-testid="extend-declined">
          <p className="alert alert--error" role="alert"><span>{done.message ?? 'The card was not charged.'} Your extension to {at(done.newReturnAt)} is approved: pay with another card.</span></p>
          {link.res && !link.res.ok && <p className="alert alert--error" role="alert"><span>{link.res.message}</span></p>}
          <button className="btn btn--primary btn--block" type="button" disabled={link.pending} data-testid="extend-pay-link"
            onClick={() => link.run(() => extensionPayLink(data.booking_number, done.extensionId ?? ''), (r) => { if (r.ok) window.location.assign(r.data.url); })}>
            {link.pending ? 'Opening' : `Pay ${$(done.totalCents)} with another card`}
          </button>
        </div>
      )}
      {o?.available && !done && (
        <div className="ext__pay">
          <button className="btn btn--primary btn--block" type="button" disabled={go.pending} data-testid="extend-pay"
            onClick={() => go.run(() => extendWithOption(data.booking_number, o.code), (r) => { if (!r.ok) return; if (r.data.state === 'link' && r.data.url) window.location.assign(r.data.url); else router.refresh(); })}>
            {go.pending ? 'Working' : data.card ? `Pay ${$(o.total_cents)} with ${brand(data.card.brand)} ending ${data.card.last4}` : `Pay ${$(o.total_cents)} by card`}
          </button>
          <p className="small"><b>New return: {at(o.new_return_at)}</b></p>
          <p className="small muted">HST included. Approved at once when the car is free; otherwise our team confirms it first and nothing is charged until then.{data.card ? '' : ' You enter the card on Stripe\'s secure page.'}</p>
        </div>
      )}
      {children}
    </div>
  );
}
