'use client';
import { useState } from 'react';
import { submitTrackerWaitlist } from '@/server/actions/trackers';
import { trackerWaitlistSchema } from '@/features/forms/schemas';
import { describedBy, Field } from '@/features/forms/Field';
import { Turnstile } from '@/features/forms/Turnstile';
import { useForm } from '@/features/forms/useForm';
import { money } from '@/lib/format';
import { Ico } from '@/features/seo/kit/icons';
import { tierFor, tierLabel, type Tier } from './pages';

// The tracker waitlist and pre-order form (release 48): two fields to join (email and the number of cars), the price for
// that many cars shown as it is typed, and the rest optional. While trackers cannot be installed it says so and charges
// nothing; when they can (Program settings, trackers_available) the same form is the order request.
export function WaitlistForm({ tiers, installCents, available, city = '', id = 'waitlist', note }: { tiers: Tier[]; installCents: number | null; available: boolean; city?: string; id?: string; note: string }) {
  const { state, run, pending, errors: e, clear } = useForm(trackerWaitlistSchema, submitTrackerWaitlist);
  const [cars, setCars] = useState('1');
  const [more, setMore] = useState(false);
  const n = Math.max(1, Math.min(500, Number(cars.replace(/\D/g, '')) || 1));
  const tier = tierFor(tiers, n);
  const p = `tw-${id}`;
  if (state?.ok) {
    return (
      <div className="sk sk-form sk-form__done" id={id} tabIndex={-1} ref={(el) => el?.focus()} data-testid="tracker-waitlist-sent" role="status">
        <span className="sk-form__tick"><Ico name="check" /></span>
        <h2>{available ? 'Request received.' : 'You are on the list.'}</h2>
        <p>{available ? 'We write back with your install day.' : 'We write to you as soon as trackers arrive, in the order people joined. Nothing is charged today.'} A confirmation is on its way to your email.</p>
      </div>
    );
  }
  return (
    <form className="sk sk-form" id={id} onSubmit={run} noValidate aria-labelledby={`${p}-h`} data-testid="tracker-waitlist-form">
      <h2 id={`${p}-h`}>{available ? 'Order a tracker' : 'Join the waitlist'}</h2>
      <p className="small" style={{ margin: 0 }} data-testid="tracker-waitlist-note">{note}</p>
      {state && !state.ok && state.code !== 'invalid' && <p className="alert alert--error" role="alert"><span>{state.message}</span></p>}
      {!available && (
        <fieldset className="sk-form__seg">
          <legend>What would you like?</legend>
          <label><input type="radio" name="want" value="waitlist" defaultChecked /><span>Tell me when it ships</span></label>
          <label><input type="radio" name="want" value="preorder" /><span>Pre-order for my cars</span></label>
        </fieldset>
      )}
      {available && <input type="hidden" name="want" value="preorder" />}
      <div className="sk-form__grid">
        <Field float id={`${p}-email`} label="Email" error={e.email}>
          <input className="input" placeholder=" " id={`${p}-email`} name="email" type="email" autoComplete="email" inputMode="email" aria-invalid={!!e.email || undefined} aria-describedby={describedBy(`${p}-email`, e.email)} onInput={() => clear('email')} />
        </Field>
        <Field float id={`${p}-cars`} label="How many cars" error={e.cars}>
          <input className="input" placeholder=" " id={`${p}-cars`} name="cars" type="text" inputMode="numeric" pattern="[0-9]*" maxLength={3} value={cars} aria-invalid={!!e.cars || undefined} aria-describedby={describedBy(`${p}-cars`, e.cars)}
            onChange={(ev) => { setCars(ev.target.value.replace(/\D/g, '')); clear('cars'); }} />
        </Field>
      </div>
      {tier && <p className="sk-form__quote" data-testid="tracker-waitlist-quote" aria-live="polite">For {n} car{n === 1 ? '' : 's'}: <b>{money(tier.monthly_cents)} a month per car</b> ({tierLabel(tier)}){n > 1 ? <>, <b>{money(tier.monthly_cents * n)}</b> a month in all</> : null}
        {installCents ? <>. Install: <b>{money(installCents)}</b> once per car</> : null}. Before HST.</p>}
      {more ? (
        <div className="sk-form__grid">
          <Field float id={`${p}-name`} label="Your name" optional error={e.name}><input className="input" placeholder=" " id={`${p}-name`} name="name" autoComplete="name" /></Field>
          <Field float id={`${p}-phone`} label="Phone" optional error={e.phone}><input className="input" placeholder=" " id={`${p}-phone`} name="phone" type="tel" autoComplete="tel" inputMode="tel" aria-invalid={!!e.phone || undefined} aria-describedby={describedBy(`${p}-phone`, e.phone)} onInput={() => clear('phone')} /></Field>
          <Field float id={`${p}-vehicle`} label="Your car (year, make, model)" optional error={e.vehicle}><input className="input" placeholder=" " id={`${p}-vehicle`} name="vehicle" /></Field>
          <Field float id={`${p}-city`} label="Where the car is (city)" optional error={e.city}><input className="input" placeholder=" " id={`${p}-city`} name="city" defaultValue={city} autoComplete="address-level2" /></Field>
        </div>
      ) : (
        <>
          {city && <input type="hidden" name="city" value={city} />}
          <button type="button" className="link small" style={{ justifySelf: 'start', minHeight: '2.75rem' }} onClick={() => setMore(true)} data-testid="tracker-waitlist-more">Add your name, phone and car (optional)</button>
        </>
      )}
      <Turnstile action="tracker_waitlist" />
      <button className="btn btn--primary btn--lg" type="submit" disabled={pending} aria-busy={pending || undefined} data-testid="tracker-waitlist-go">{pending ? 'Sending' : available ? 'Send my order request' : 'Join the waitlist'}</button>
    </form>
  );
}
