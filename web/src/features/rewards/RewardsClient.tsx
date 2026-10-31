'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { cancelRewardCode, claimGoogleReview, redeemPoints } from '@/server/actions/rewards';
import { money } from '@/lib/format';
import { pointsWorth, redeemSteps } from './types';

// The renter's Rewards actions (migration 0214): turn points into a code, give an unused code back, claim a Google review.
export function Redeem({ balance, min, centsPerPoint, validDays }: { balance: number; min: number; centsPerPoint: number; validDays: number }) {
  const steps = redeemSteps(balance, min);
  const [points, setPoints] = useState(steps[0] ?? 0);
  const { pending, res, run } = useAct<{ code: string; amount_cents: number; valid_until: string }>();
  const router = useRouter();
  if (!steps.length) return <p className="small muted" data-testid="rewards-redeem-min">You can redeem from {min.toLocaleString('en-CA')} points.</p>;
  return (
    <div className="stack" data-testid="rewards-redeem">
      <div className="field">
        <label htmlFor="rw-points">Points to use</label>
        <select id="rw-points" value={points} onChange={(e) => setPoints(Number(e.target.value))}>
          {steps.map((p) => <option key={p} value={p}>{p.toLocaleString('en-CA')} points: {money(pointsWorth(p, centsPerPoint), { cents: true })} off</option>)}
        </select>
      </div>
      <button type="button" className="btn btn--primary" disabled={pending} onClick={() => run(() => redeemPoints(points), (r) => { if (r.ok) router.refresh(); })}>
        {pending ? 'Making your code' : 'Get my code'}
      </button>
      <p className="xs muted">A code of your own for one booking, valid {validDays} days. Type it in the promo code box of your request. It comes off the rental charge only.</p>
      {res && (res.ok ? <p className="small" role="status" data-testid="rewards-code-new">Your code: <b>{res.data?.code}</b>, {money(res.data?.amount_cents ?? 0, { cents: true })} off.</p>
        : <p className="error" role="alert">{res.message}</p>)}
    </div>
  );
}

export function CancelCode({ code }: { code: string }) {
  const { pending, res, run } = useAct<{ points: number }>();
  const router = useRouter();
  return <>
    <button type="button" className="btn btn--quiet btn--sm" disabled={pending} onClick={() => run(() => cancelRewardCode(code), (r) => { if (r.ok) router.refresh(); })}>Give back for points</button>
    {res && !res.ok && <span className="error" role="alert">{res.message}</span>}
  </>;
}

export function GoogleClaim({ number }: { number: string }) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState('');
  const { pending, res, run, err } = useAct<{ points: number }>();
  const router = useRouter();
  if (res?.ok) return <p className="small" role="status">Thank you. {res.data?.points} points added.</p>;
  if (!open) return <button type="button" className="btn btn--ghost btn--sm" onClick={() => setOpen(true)} data-testid={`rewards-google-posted-${number}`}>I posted my review</button>;
  const id = `rw-name-${number}`;
  return (
    <form className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap', alignItems: 'flex-end' }} onSubmit={(e) => { e.preventDefault(); run(() => claimGoogleReview(number, name), (r) => { if (r.ok) router.refresh(); }); }}>
      <div className="field">
        <label htmlFor={id}>The name shown on your review</label>
        <input id={id} value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" required minLength={2} maxLength={80} aria-invalid={!!err('name')} />
      </div>
      <button type="submit" className="btn btn--primary btn--sm" disabled={pending}>Add my points</button>
      {res && !res.ok && <p className="error" role="alert">{res.message}</p>}
    </form>
  );
}

export function CopyLink({ url }: { url: string }) {
  const [done, setDone] = useState(false);
  return <button type="button" className="btn btn--ghost btn--sm" onClick={() => { void navigator.clipboard?.writeText(url).then(() => setDone(true)); }}>{done ? 'Copied' : 'Copy my link'}</button>;
}
