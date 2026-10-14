'use client';
import { useState } from 'react';
import { submitReview } from '@/server/actions/portal';
import { useAct } from './useAct';

// The renter's review of a closed booking: stars as radio buttons (keyboard and screen reader friendly),
// an optional title and text, and the consent to show it on the site. Staff publish it after a read.
export function ReviewForm({ number, googleUrl }: { number: string; googleUrl: string | null }) {
  const [rating, setRating] = useState(0);
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [consent, setConsent] = useState(true);
  const a = useAct();
  if (a.res?.ok) return (
    <div className="pt-ok" role="status" data-testid="review-thanks"><h2 className="d4">Thank you</h2>
      <p>Your review is with our team. Once read, it appears on the car&apos;s page{consent ? '' : ' only if you agree later'}.</p>
      {googleUrl && <p><a className="btn btn--ghost" href={googleUrl} target="_blank" rel="noopener">Also review us on Google</a></p>}
      <p><a className="btn btn--primary" href={`/account/bookings/${encodeURIComponent(number)}`}>Back to the booking</a></p>
    </div>
  );
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => submitReview(number, { rating, title, body, consent })); }} data-testid="review-form">
      <fieldset className={`field${a.err('rating') ? ' has-error' : ''}`} style={{ border: 0, padding: 0, margin: 0 }}>
        <legend className="label">Your rating</legend>
        <div className="pt-stars" role="radiogroup" aria-describedby="pt-rating-err">
          {[1, 2, 3, 4, 5].map((n) => (
            <label key={n} className={`pt-star${n <= rating ? ' is-on' : ''}`}>
              <input type="radio" name="rating" value={n} checked={rating === n} onChange={() => setRating(n)} className="vh" />
              <span aria-hidden="true">★</span><span className="vh">{n} {n === 1 ? 'star' : 'stars'}</span>
            </label>
          ))}
        </div>
        <p className="error" role="alert" id="pt-rating-err">{a.err('rating') ?? ''}</p>
      </fieldset>
      <div className={`field${a.err('title') ? ' has-error' : ''}`}>
        <label className="label" htmlFor="pt-review-title">Title <span className="muted">(optional)</span></label>
        <input className="input" id="pt-review-title" value={title} maxLength={120} onChange={(e) => setTitle(e.target.value)} />
        <p className="error" role="alert">{a.err('title') ?? ''}</p>
      </div>
      <div className={`field${a.err('body') ? ' has-error' : ''}`}>
        <label className="label" htmlFor="pt-review-body">Your review <span className="muted">(optional)</span></label>
        <textarea className="textarea" id="pt-review-body" rows={5} value={body} maxLength={2000} onChange={(e) => setBody(e.target.value)} />
        <p className="hint">The car, the pickup, the return: what should the next renter know?</p>
        <p className="error" role="alert">{a.err('body') ?? ''}</p>
      </div>
      <label className="check" htmlFor="pt-review-consent"><input id="pt-review-consent" type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} /> <span>Show my review on the site with my first name</span></label>
      {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--warn" role="alert"><span>{a.res.message}</span></p>}
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Sending' : 'Send my review'}</button>
    </form>
  );
}
