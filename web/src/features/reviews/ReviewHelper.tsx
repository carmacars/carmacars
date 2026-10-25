'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import { reviewHelperAct } from '@/server/actions/review-helper';
import { draftReview, hasInput, LIKED, LIKED_LABEL, SENTENCE_MAX, unhappy, type DraftFacts, type Liked } from './draft';
import './review-helper.css';

// The review helper (migration 0146, docs/changes/2026-10-24-review-requests.md): three quick questions (what they
// liked, an optional star feel, one sentence), then a short draft made only from their answers and the booking's facts,
// which they edit, copy and post on Google. Everyone gets the Google link whatever their stars; a low star feel also
// shows "Something wasn't right? Tell us directly". Nothing is written for them before they answer.
export interface HelperProps {
  token: string;
  firstName: string;
  bookingNumber: string;
  facts: DraftFacts;
  googleUrl: string | null;
  reviewed: boolean;
  /** opened from "I already left a review" in an email: ask to confirm first */
  confirmDone?: boolean;
  /** where "Tell us directly" goes: the booking's messages (signed in) or the contact address */
  directHref: string;
  directLabel: string;
  phone: string | null;
}

export function ReviewHelper(p: HelperProps) {
  const [liked, setLiked] = useState<Liked[]>([]);
  const [staff, setStaff] = useState<string[]>([]);
  const [stars, setStars] = useState<number | null>(null);
  const [sentence, setSentence] = useState('');
  const [seed, setSeed] = useState(0);
  const [text, setText] = useState('');
  const [edited, setEdited] = useState(false);
  const [copied, setCopied] = useState<'' | 'copied' | 'failed'>('');
  const [done, setDone] = useState(p.reviewed);
  const [busy, setBusy] = useState(false);
  const area = useRef<HTMLTextAreaElement>(null);
  const answers = useMemo(() => ({ liked, staff, stars, sentence }), [liked, staff, stars, sentence]);
  const ready = hasInput(answers, p.facts);
  const draft = useMemo(() => draftReview(p.facts, answers, seed), [p.facts, answers, seed]);

  // the draft follows the answers until the renter types in it
  const shown = edited ? text : draft;
  // counted once the page is open in a browser (a mail scanner's visit is not)
  useEffect(() => { void reviewHelperAct(p.token, 'opened'); }, [p.token]);

  const toggle = <T,>(xs: T[], x: T) => (xs.includes(x) ? xs.filter((y) => y !== x) : [...xs, x]);
  async function copy(): Promise<boolean> {
    try {
      await navigator.clipboard.writeText(shown);
      setCopied('copied');
      void reviewHelperAct(p.token, 'copied');
      return true;
    } catch {
      // no clipboard (an old browser, a page without permission): select the text so a long press copies it
      area.current?.focus(); area.current?.select();
      setCopied('failed');
      return false;
    }
  }
  async function already() {
    setBusy(true);
    const r = await reviewHelperAct(p.token, 'reviewed');
    setBusy(false);
    if (r.ok) setDone(true);
  }

  if (done) return (
    <div className="rh-done" role="status" data-testid="review-helper-done">
      <h2 className="d4">Thank you, {p.firstName}</h2>
      <p>We will not ask you for a review of this trip again.</p>
    </div>
  );

  const low = unhappy(stars);
  return (
    <div className="rh" data-testid="review-helper">
      {p.confirmDone && (
        <div className="rh-done" data-testid="review-confirm-done">
          <p><b>Already left a review?</b> Press the button and we stop asking about this trip.</p>
          <p><button type="button" className="btn btn--primary" disabled={busy} onClick={already} data-testid="review-already">I already left a review</button></p>
        </div>
      )}
      <fieldset className="rh-step">
        <legend>1. What did you like?</legend>
        <ul className="rh-chips">
          {LIKED.map((k) => (
            <li key={k}><button type="button" className="rh-chip" aria-pressed={liked.includes(k)} onClick={() => setLiked((xs) => toggle(xs, k))} data-testid={`chip-${k}`}>
              {k === 'handover' ? (p.facts.delivered ? 'The delivery' : 'The pickup') : LIKED_LABEL[k]}</button></li>
          ))}
          {p.facts.staff.map((n) => (
            <li key={`staff-${n}`}><button type="button" className="rh-chip" aria-pressed={staff.includes(n)} onClick={() => setStaff((xs) => toggle(xs, n))} data-testid={`chip-staff-${n}`}>{n}</button></li>
          ))}
        </ul>
      </fieldset>
      <fieldset className="rh-step">
        <legend>2. How did it feel? <span className="muted">(optional)</span></legend>
        <div className="rh-stars" role="radiogroup" aria-label="How did it feel, 1 to 5 stars">
          {[1, 2, 3, 4, 5].map((n) => (
            <label key={n} className={`rh-star${stars !== null && n <= stars ? ' is-on' : ''}`}>
              <input type="radio" name="rh-stars" value={n} checked={stars === n} onChange={() => setStars(n)} className="rh-sr" />
              <span aria-hidden="true">{'★'}</span><span className="rh-sr">{n} {n === 1 ? 'star' : 'stars'}</span>
            </label>
          ))}
          {stars !== null && <button type="button" className="btn btn--quiet btn--sm" onClick={() => setStars(null)}>Clear</button>}
        </div>
      </fieldset>
      <div className="rh-step">
        <label className="rh-q" htmlFor="rh-sentence">3. One sentence in your own words <span className="muted">(optional)</span></label>
        <input id="rh-sentence" className="rh-input" value={sentence} maxLength={SENTENCE_MAX} onChange={(e) => setSentence(e.target.value)} placeholder="For example: what made the trip easy" data-testid="review-sentence" />
      </div>

      {low && (
        <div className="rh-direct" data-testid="review-direct">
          <p><b>Something wasn&apos;t right?</b> Tell us directly and a person will make it right.</p>
          <p><a className="btn btn--ghost btn--sm" href={p.directHref} onClick={() => void reviewHelperAct(p.token, 'unhappy')} data-testid="review-direct-link">{p.directLabel}</a>
            {p.phone ? <> or call <a className="link" href={`tel:${p.phone.replace(/[^0-9+]/g, '')}`}>{p.phone}</a></> : null}</p>
        </div>
      )}

      <section className="rh-draft" aria-labelledby="rh-draft-h">
        <h2 className="d4" id="rh-draft-h">Your review</h2>
        {!ready ? (
          <p className="rh-note" data-testid="review-draft-empty">Tap what you liked or write a sentence, and your draft appears here. We only use what you tell us and the facts of your booking.</p>
        ) : (<>
          <label className="rh-sr" htmlFor="rh-text">Your review, change anything you like</label>
          <textarea id="rh-text" ref={area} className="rh-input" value={shown} maxLength={2000} onChange={(e) => { setText(e.target.value); setEdited(true); setCopied(''); }} data-testid="review-draft" />
          <p className="rh-note">Change anything you like: it is your review.{' '}
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => { setEdited(false); setSeed((s) => s + 1); setCopied(''); }} data-testid="review-other-words">Other words</button></p>
          <div className="rh-actions">
            <button type="button" className="btn btn--ghost" onClick={() => void copy()} disabled={!shown.trim()} data-testid="review-copy">{copied === 'copied' ? 'Copied' : 'Copy'}</button>
            {p.googleUrl && (
              <a className="btn btn--primary" href={p.googleUrl} target="_blank" rel="noopener" data-testid="review-google"
                onClick={() => { void copy(); void reviewHelperAct(p.token, 'google'); }}>Post on Google</a>
            )}
          </div>
          <p className="rh-note" role="status">{copied === 'copied' ? 'Copied. On Google, choose your stars and paste it in the box.' : copied === 'failed' ? 'Select the text above and copy it, then paste it on Google.' : p.googleUrl ? 'Post on Google copies your review and opens Google: choose your stars and paste it.' : ''}</p>
        </>)}
        {!p.googleUrl && <p className="rh-note">Our Google review link is not set up yet. Copy your review and keep it for us, or send it to us directly.</p>}
      </section>

      {!p.confirmDone && (
        <p className="rh-note">Already left a review? <button type="button" className="btn btn--quiet btn--sm" disabled={busy} onClick={already} data-testid="review-already">I already left a review</button></p>
      )}
    </div>
  );
}
