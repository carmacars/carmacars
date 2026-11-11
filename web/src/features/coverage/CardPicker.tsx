'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { confirmCardCoverage, previewCardCoverage } from '@/server/actions/portal';
import { cardName, searchCards, type CardRow } from './cards';
import type { CardPick, CardProductCheck } from './types';

// Coverage option 2 (1400): the renter finds their card (issuer and card) in the list, sees at once whether it covers this
// car (the database's app.card_product_check: the card's coverage, the car's value against the card's limit, the car's
// type against the card's exclusions, the length of the rental), then ticks and confirms. A card that does not cover the
// car says why and points to the other options; a card that is not listed, or not known well enough, goes to our team.
export function CardPicker({ number, cards, pick, vehicleClass, rentalDays }: {
  number: string; cards: CardRow[]; pick: CardPick | null; vehicleClass: string | null; rentalDays: number;
}) {
  const router = useRouter();
  const id = useId();
  const [pending, start] = useTransition();
  const [q, setQ] = useState('');
  const [chosen, setChosen] = useState<{ id: string | null; label: string } | null>(pick ? { id: pick.card_id, label: pick.label ?? '' } : null);
  const [other, setOther] = useState(pick?.card_other ?? '');
  const [notListed, setNotListed] = useState(!!pick?.card_other);
  const [check, setCheck] = useState<CardProductCheck | null>(pick?.check ?? null);
  const [tick, setTick] = useState(false);
  const [msg, setMsg] = useState('');
  const found = searchCards(cards.filter((c) => c.country === 'CA'), q, 8);
  const choose = (c: { id: string | null; label: string }) => {
    setChosen(c); setMsg(''); setCheck(null);
    start(async () => { const r = await previewCardCoverage(number, c.id); if (r.ok) setCheck(r.data); else setMsg(r.message ?? 'Something went wrong.'); });
  };
  const refused = check?.result === 'not_covered';
  const ready = !!chosen && (chosen.id || other.trim()) && !refused && !pending;
  return (
    <div className="stack" data-testid="card-picker">
      <div className="field">
        <label className="label" htmlFor={`${id}-q`}>Which credit card is it?</label>
        <input className="input" id={`${id}-q`} type="search" value={q} placeholder="Search: bank and card, for example TD Aeroplan" autoComplete="off"
          onChange={(e) => setQ(e.target.value)} data-testid="card-picker-search" aria-describedby={`${id}-hint`} />
        <p className="small muted" id={`${id}-hint`}>Pick the exact card. We check its rental car coverage against this car and these dates.</p>
      </div>
      {!notListed && (
        <ul className="stack" aria-label="Cards" data-testid="card-picker-list" style={{ listStyle: 'none', padding: 0, margin: 0, gap: 'var(--s-1)' }}>
          {found.map((c) => (
            // a list of buttons (a button inside role="option" is nested-interactive): the chosen one is pressed
            <li key={c.id}>
              <button type="button" aria-pressed={chosen?.id === c.id} className={`btn btn--sm ${chosen?.id === c.id ? 'btn--primary' : 'btn--ghost'}`} onClick={() => choose({ id: c.id, label: cardName(c) })}
                disabled={pending} data-testid="card-picker-option">{cardName(c)}</button>
            </li>))}
          {found.length === 0 && <li className="small muted">No card matches. Try fewer words, or say your card is not listed.</li>}
        </ul>)}
      <label className="check"><input type="checkbox" checked={notListed} onChange={(e) => { setNotListed(e.target.checked); setChosen(e.target.checked ? { id: null, label: other } : null); setCheck(null); }}
        data-testid="card-picker-not-listed" /> <span>My card is not on the list</span></label>
      {notListed && (
        <div className="field">
          <label className="label" htmlFor={`${id}-other`}>The card&apos;s bank and name</label>
          <input className="input" id={`${id}-other`} value={other} maxLength={120} onChange={(e) => { setOther(e.target.value); setChosen({ id: null, label: e.target.value }); }}
            onBlur={() => other.trim() && choose({ id: null, label: other.trim() })} data-testid="card-picker-other" />
        </div>)}
      {pending && <p className="small muted" role="status">Checking the card against this car…</p>}
      {check && (
        <p className={`alert ${check.result === 'covered' ? 'alert--ok' : check.result === 'review' ? 'alert--warn' : 'alert--error'}`} role={refused ? 'alert' : 'status'} data-testid="card-picker-result" data-result={check.result}>
          <span className="alert__title">{check.result === 'covered' ? 'This card covers this car' : check.result === 'review' ? 'Our team checks this card' : 'This card does not cover this car'}</span>
          <span>{check.message}</span>
          {check.source_url && <span className="small"> <a className="link" href={check.source_url} target="_blank" rel="noopener">The card&apos;s guide</a></span>}
        </p>)}
      {refused && <p className="small" data-testid="card-picker-other-options">Use the buttons below to switch to OPCF 27 on your own auto policy, or ask for the CarmaCars Protection Plan.</p>}
      {chosen && !refused && (
        <form className="stack" onSubmit={(e) => { e.preventDefault(); start(async () => {
          const r = await confirmCardCoverage(number, tick, '', { id: chosen.id, other: chosen.id ? null : other });
          setMsg(r.ok ? 'Thanks. Our team checks it before pickup.' : (r.message ?? 'Something went wrong.')); if (r.ok) router.refresh();
        }); }}>
          <label className="check"><input type="checkbox" checked={tick} onChange={(e) => setTick(e.target.checked)} data-testid="coverage-card-tick" />{' '}
            <span>My {chosen.label || 'credit card'} includes rental car coverage for a {vehicleClass ?? 'car of this class'} for {rentalDays} {rentalDays === 1 ? 'day' : 'days'}, and I will claim on it if the car is damaged.</span></label>
          <button className="btn btn--primary" type="submit" disabled={!tick || !ready} data-testid="coverage-card-confirm">{pending ? 'Saving' : 'Confirm my card’s coverage'}</button>
        </form>)}
      {msg && <p className="small" role="status" data-testid="card-picker-msg">{msg}</p>}
    </div>
  );
}
