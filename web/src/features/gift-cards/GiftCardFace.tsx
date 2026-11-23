import { money } from '@/lib/format';

// The gift card as people see it (migration 3600): on the buy page while it is filled in, after paying, and on the
// printable card. Black with the brand's red glow, the amount large, who it is for and, once paid, the code.
export function GiftCardFace({ amountCents, to, kindLabel, code, rentalText }: { amountCents: number | null; to: string; kindLabel: string; code: string | null; rentalText?: string | null }) {
  return (
    <div className="gc-card" role="img" aria-label={`CarmaCars ${kindLabel.toLowerCase()}${amountCents ? ` of ${money(amountCents, { cents: true })}` : ''} for ${to}`} data-testid="gift-card-face">
      <div className="gc-card__top"><span className="gc-card__brand">CarmaCars</span><span className="gc-card__kind">{kindLabel}</span></div>
      <span className="gc-card__amt">{amountCents ? money(amountCents, { cents: true }) : '$0.00'}</span>
      <div className="gc-card__foot">
        <span className="gc-card__to">For {to}</span>
        {rentalText && <span className="gc-card__code">{rentalText}</span>}
        {code && <span className="gc-card__code" data-testid="gift-card-code">{code}</span>}
      </div>
    </div>
  );
}
