'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { chargeSavedCard, startCardRequest } from '@/server/actions/offers';

// What is open after a change, and the ways to settle it in one place (migration 0132): a pay link for exactly the
// balance, by email or text (the renter pays by card on Stripe's form; the email says what changed), the saved card
// charged (Finance or an Admin, with the renter's agreement), or the payment recorded on the Money tab.
export function BalanceActions({ booking, open, rental, fees, card, reach, why }: { booking: string; open: number; rental?: number; fees?: number;
  card?: { brand: string; last4: string } | null; reach?: { email: boolean; mobile: boolean } | null; why?: string }) {
  const router = useRouter();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  if (open <= 0) return <p className="small muted" data-testid="bal-none">Nothing is open on this booking.</p>;
  const reason = why ? `the new balance of your booking (${why})` : 'the balance of your booking';
  const send = (channel: 'email' | 'text') => run(async () => {
    const r = await startCardRequest({ booking, kind: 'charge', covers: 'balance', amount_cents: open, reason, channel });
    setMsg(r.ok ? { ok: !!r.data.sent?.ok || !r.data.sent, text: r.data.sent?.ok === false ? `Not sent: ${r.data.sent.reason}` : `The renter has a pay link for ${money(open, { cents: true })} by ${channel === 'email' ? 'email' : 'text'}.` } : { ok: false, text: r.message });
    router.refresh();
  });
  const charge = () => run(async () => {
    const r = await chargeSavedCard({ booking, amount_cents: open, reason: why ?? 'The balance of the booking', covers: 'rental' });
    setMsg(r.ok ? { ok: r.data.ok, text: r.data.ok ? `${money(open, { cents: true })} charged to the saved card.` : `Not charged: ${r.data.message}` } : { ok: false, text: r.message });
    router.refresh();
  });
  return (
    <div className="alert alert--warn stack" role="status" data-testid="bal-open">
      <p><b>Open now: {money(open, { cents: true })}</b>{rental !== undefined && fees !== undefined ? ` (rental ${money(rental, { cents: true })}, fees ${money(fees, { cents: true })})` : ''}. Tell the renter and take the payment:</p>
      <div className="row">
        {/* 2026-11-01: by text first; without a mobile number, by email */}
        {reach?.mobile && <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={() => send('text')} data-testid="bal-text">Text a pay link</button>}
        {reach?.email !== false && <button className={`btn ${reach?.mobile ? 'btn--ghost' : 'btn--primary'} btn--sm`} type="button" disabled={pending} onClick={() => send('email')} data-testid="bal-email">Email a pay link</button>}
        {reach && !reach.mobile && <span className="small muted" data-testid="bal-no-mobile">No mobile number on file: the link goes by email.</span>}
        {card && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={charge} data-testid="bal-charge">Charge {card.brand} {card.last4} (renter agreed)</button>}
        <a className="btn btn--quiet btn--sm" href={`?tab=money#bm-h`}>Record cash or e-Transfer</a>
      </div>
      {msg && <p className={msg.ok ? 'small' : 'small ad-late'} data-testid="bal-msg">{msg.text}</p>}
    </div>
  );
}
