// The investor video's view of the deck (docs/investor-video/script.md): the deck itself, rendered to static markup with
// the same figures (app.deck_figures()) and the same formulas, so every slide and every number in the video is the
// deck's own. Bundled by build.mjs with esbuild ('@/' is web/src; next/link is a plain link).
import { renderToStaticMarkup } from 'react-dom/server';
import { Deck } from '@/features/deck/Deck';
import { FEATURE_GROUPS } from '@/features/deck/features';
import { computeReturns, firstOfNextMonth } from '@/features/deck/returns';
import type { DeckFigures } from '@/features/deck/types';
import { money } from '@/lib/format';

// The words the narration may use, computed exactly as Deck.tsx computes them (keep in step with it).
const $ = (c: number | null | undefined) => (c === null || c === undefined ? '' : money(c));
const $c = (c: number) => money(c, { cents: true });
const pctOf = (bps: number | null | undefined) => (bps === null || bps === undefined ? '' : `${+(bps / 100).toFixed(2)}%`);

export function deckForVideo(f: DeckFigures, today: string) {
  const b = f.brand;
  const mult = Number(f.settings.deck_multiplier);
  const bps = f.settings.deck_return_bps;
  const inv = f.investment;
  const shares = f.owner_tiers.map((t) => t.revenue_share_bps);
  const fees = f.owner_tiers.map((t) => t.monthly_fees_cents);
  const minC = inv.min_cents;
  const start = firstOfNextMonth(today);
  const first = computeReturns({ amountCents: minC, yearlyBps: bps, investmentDate: start, years: 1, reinvestMonths: 0, lockupMonths: inv.lockup_months, paymentDay: inv.payment_day });
  const examples = [minC, ...(minC < 5_000_000 ? [5_000_000] : [])];
  const vars: Record<string, string> = {
    brand: 'CarmaCars',
    area: b.service_area ?? b.city ?? 'Ontario',
    tagline: b.tagline ?? 'Car rental, run on our own platform.',
    mult: `${+mult.toFixed(2)}x`,
    yearly: pctOf(bps),
    min: $(minC),
    lockup: String(inv.lockup_months),
    payDay: `${inv.payment_day}th`,
    monthly: first.monthlyPaymentCents !== null ? $c(first.monthlyPaymentCents) : '',
    monthsToFirst: first.monthsToFirstPayment !== null ? String(first.monthsToFirstPayment) : '',
    y1months: String(12 - inv.lockup_months),
    exampleAmounts: examples.map((x) => $(x)).join(' and '),
    shareRange: shares.length ? `${pctOf(Math.min(...shares))} to ${pctOf(Math.max(...shares))}` : '',
    feeRange: fees.length ? `${$(Math.min(...fees))} to ${$(Math.max(...fees))}` : '',
    partner: pctOf(f.partner_commission_bps),
    days: String(f.sample.days),
    total: $c(f.sample.total_cents),
    phone: b.phone ?? '',
    email: b.email ?? ''
  };
  const groups = FEATURE_GROUPS.map((g) => ({ id: g.id, kicker: g.kicker, features: g.features.length }));
  const html = renderToStaticMarkup(<Deck f={f} today={today} />);
  return { html, vars, groups };
}
