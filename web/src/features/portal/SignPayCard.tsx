import Link from '@/components/Link';
import { bookingPath } from './status';
import { signPayOf, signPayOpen, signPayWords } from './sign-pay';
import type { BookingSummary } from './types';

// The one card for a booking still to sign or pay (r33, the owner: "a clear way to SIGN and PAY"): what is left in one
// sentence, with the amount, and the one button to the Sign and pay page. From the one rule (0750). Nothing when done.
/** quiet (r40): a second trip's card under the page's Do this next card: its button is plain, the red one is the card's. */
export function SignPayCard({ b, testId = 'sign-pay-card', label, quiet }: { b: Pick<BookingSummary, 'booking_number' | 'sign_pay'>; testId?: string; label?: string; quiet?: boolean }) {
  const s = signPayOf(b);
  const w = signPayWords(s);
  if (!w || !signPayOpen(s)) return null;
  return (
    <section className="sp-left" aria-labelledby={`${testId}-h`} data-testid={testId} data-step={s.step}>
      <h2 className="sp-left__title" id={`${testId}-h`}>{w.title}{label ? <span className="small muted"> · {label}</span> : null}</h2>
      <p className="sp-left__text" data-testid={`${testId}-left`}>{w.left}</p>
      <Link prefetch={false} className={`btn ${quiet ? 'btn--ghost' : 'btn--primary'}`} href={bookingPath(b.booking_number, 'checkout')} data-testid={`${testId}-go`}>{w.cta}</Link>
    </section>
  );
}
