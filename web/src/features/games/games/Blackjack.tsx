'use client';
import { useMemo, useRef, useState } from 'react';
import { deck, handValue, settle, type HandResult } from '../rules';
import type { GameProps } from '../GamePopup';

// Quick blackjack: one hand against the dealer (dealer draws to 17). The prize does not depend on the hand: win or
// lose, the visitor gets the prize the database drew.
const SUITS = ['♠', '♥', '♦', '♣'];
const RANK = (c: number) => (c === 1 ? 'A' : c === 11 ? 'J' : c === 12 ? 'Q' : c === 13 ? 'K' : String(c));
const NAME = (c: number) => (c === 1 ? 'ace' : c === 11 ? 'jack' : c === 12 ? 'queen' : c === 13 ? 'king' : String(c));
const WORDS: Record<HandResult, string> = { blackjack: 'Blackjack! You beat the dealer.', win: 'You beat the dealer.', push: 'A tie with the dealer.', lose: 'The dealer wins this one.', bust: 'Over 21. The dealer wins this one.' };

function Card({ c, i, down }: { c: number; i: number; down?: boolean }) {
  const suit = SUITS[(c + i) % 4]!;
  return down ? <span className="ccg-card is-down" role="img" aria-label="A card face down" />
    : <span className={`ccg-card${suit === '♥' || suit === '♦' ? ' is-red' : ''}`} role="img" aria-label={NAME(c)}>{RANK(c)}{suit}</span>;
}

export default function Blackjack({ prize, onReveal }: GameProps) {
  const cards = useMemo(() => deck(Math.random), []);
  const next = useRef(4);
  const draw = () => cards[next.current++ % 52]!;
  const [player, setPlayer] = useState<number[]>(() => [cards[0]!, cards[2]!]);
  const [dealer, setDealer] = useState<number[]>(() => [cards[1]!, cards[3]!]);
  const [result, setResult] = useState<HandResult | null>(null);
  function finish(hand: number[]) {
    const s = settle(hand, dealer, draw);
    setDealer(s.dealer); setResult(s.result);
  }
  function hit() {
    const h = [...player, draw()];
    setPlayer(h);
    if (handValue(h) >= 21) finish(h);
  }
  const pv = handValue(player);
  return (
    <div className="ccg-stage">
      <div className="ccg-table">
        <div className="ccg-hand"><span className="ccg-hand__label">Dealer{result ? `: ${handValue(dealer)}` : ''}</span>
          <div className="ccg-cards">{dealer.map((c, i) => <Card key={i} c={c} i={i + 1} down={!result && i === 1} />)}</div></div>
        <div className="ccg-hand"><span className="ccg-hand__label">You: {pv}</span>
          <div className="ccg-cards">{player.map((c, i) => <Card key={i} c={c} i={i} />)}</div></div>
      </div>
      <p className="ccg-live" aria-live="polite">{result ? <>{WORDS[result]} You still win <b>{prize.label}</b>.</> : `You have ${pv}. Hit for another card or stand.`}</p>
      {!result ? <div className="ccg-row">
        <button type="button" className="btn btn--ghost" onClick={hit} data-testid="game-hit">Hit</button>
        <button type="button" className="btn btn--primary" onClick={() => finish(player)} data-testid="game-action">Stand</button>
      </div> : <button type="button" className="btn btn--primary ccg-play" onClick={onReveal} data-testid="game-next">Claim your prize</button>}
    </div>
  );
}
