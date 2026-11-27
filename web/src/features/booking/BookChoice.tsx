'use client';
import './book-choice.css';
import Link from '@/components/Link';
import { useEffect, useState } from 'react';
import { instantOffer } from '@/server/actions/booking';
import { instantWhyNot, type BookHow } from './book-choice-rules';
export type { BookHow };

// r50 (3900): the renter chooses how to book, on the car page and in the booking flow: Book instantly (pay now and it is
// confirmed) or Request to book (no charge; staff approve, then send a pay link or an offer). Book instantly is open only
// to a renter the database lets book at once (app.instant_book_check: a complete profile, licence verified, nothing owing; 5113) and only for
// a car and dates it can take at once; everyone else sees why. Request to book is the default, as it always was.

/** The hint this device's renter may book instantly (set by the renter portal and the booking flow; only a hint: the
 *  database decides again when the request is sent). */
export const INSTANT_COOKIE = 'cc-instant';
export function instantHinted(): boolean {
  try { return document.cookie.split('; ').some((c) => c === `${INSTANT_COOKIE}=1`); } catch { return false; }
}
export function setInstantHint(on: boolean) {
  try {
    const secure = location.protocol === 'https:' ? '; secure' : '';
    document.cookie = on ? `${INSTANT_COOKIE}=1; path=/; max-age=${30 * 86400}; samesite=lax${secure}` : `${INSTANT_COOKIE}=; path=/; max-age=0; samesite=lax${secure}`;
  } catch { /* cookies off: the car page offers Request to book */ }
}

/** The renter portal keeps the hint in step with the database (no hint: the car page never asks the server). */
export function InstantHint({ on }: { on: boolean }) {
  useEffect(() => { setInstantHint(on); }, [on]);
  return null;
}

/** The car page asks the server once, only on a device whose renter could book instantly. */
export function useInstantOffer(): { canBookNow: boolean; cardsOn: boolean } {
  const [s, setS] = useState({ canBookNow: false, cardsOn: true });
  useEffect(() => {
    if (!instantHinted()) return;
    let live = true;
    instantOffer().then((x) => { if (!live) return; setS(x); if (!x.canBookNow) setInstantHint(false); }).catch(() => undefined);
    return () => { live = false; };
  }, []);
  return s;
}

export function BookChoice({ value, onChange, canBookNow, cardsOn, carOk = true, idPrefix }: {
  value: BookHow; onChange: (v: BookHow) => void; canBookNow: boolean; cardsOn: boolean; carOk?: boolean; idPrefix: string;
}) {
  const why = instantWhyNot({ canBookNow, carOk });
  const name = `${idPrefix}-how`;
  return (
    <fieldset className="bkc stack" data-testid={`${idPrefix}-book-choice`}>
      <legend className="label">How do you want to book?</legend>
      <label className="option bkc__opt" data-testid={`${idPrefix}-how-request`}>
        <input type="radio" name={name} value="request" checked={value === 'request'} onChange={() => onChange('request')} />
        <span className="option__title">Request to book</span>
        <span className="option__body">No charge now. We check the car and send you a pay link or an offer to approve.</span>
      </label>
      <label className={`option bkc__opt${why ? ' is-off' : ''}`} data-testid={`${idPrefix}-how-instant`}>
        <input type="radio" name={name} value="instant" checked={value === 'instant' && !why} disabled={!!why} onChange={() => onChange('instant')} aria-describedby={`${name}-i`} />
        <span className="option__title">Book instantly</span>
        <span className="option__body" id={`${name}-i`}>{why
          ? <>{why}{!canBookNow && <> <Link prefetch={false} className="link" href="/account/rewards">Rewards</Link></>}</>
          : cardsOn ? 'Pay now and the car is yours: confirmed at the website price.'
            : 'Pay now by Interac e-Transfer (card payments are paused): confirmed once we see it.'}</span>
      </label>
    </fieldset>
  );
}
