'use client';
import { lazy, Suspense, useState, useTransition, type ComponentType } from 'react';
import { AnimatedNumber } from '@/components/portal-ui';
import { WhyDisabled } from '@/components/WhyDisabled';
import { motionOK } from '@/lib/motion';
import { playMoment } from '@/features/motion/moment';
import { GAME_LOAD } from '@/features/games/load';
import type { GameProps } from '@/features/games/GamePopup';
import { rewardsGamePlay } from '@/server/actions/rewards-game';
import { gameLine, pointsWhere, type GamePlay, type GamePortal, type GameState } from './game-model';

// r50 hotfix 2 (5151): the game card in Rewards. Play asks the database for a play (the day's cap, the prize drawn
// there, the points credited there); then the game of that play runs here only to show the prize, and the balance rolls
// up to the new total with the confetti. A double tap never plays twice (the button is busy, the database locks).
/** the games, lazy, made once for the module (never during a render) */
const LAZY = Object.fromEntries(Object.entries(GAME_LOAD).map(([k, f]) => [k, lazy(f)])) as Record<string, ComponentType<GameProps>>;
const TITLE: Record<string, string> = { wheel: 'Spin the wheel', scratch: 'Scratch the card', blackjack: 'Beat the dealer', cups: 'Find the ball', plinko: 'Drop the disc', pack: 'Rip the pack',
  coin: 'Flip the coin', dice: 'Roll the dice', slots: 'Pull the lever', drop: 'Turn the handle', mystery: 'Pick a box' };

export function RewardsGameClient({ portal, initial }: { portal: GamePortal; initial: GameState }) {
  const [s, setS] = useState<GameState>(initial);
  const [play, setPlay] = useState<GamePlay | null>(null);
  const [revealed, setRevealed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, start] = useTransition();
  const reduced = typeof window !== 'undefined' && !motionOK();
  const shown = play && revealed ? play : s;
  const points = shown.has_account ? shown.balance ?? 0 : shown.waiting;

  const go = () => start(async () => {
    setError(null);
    const r = await rewardsGamePlay(portal);
    if (!r.ok) { setError(r.message); return; }
    setRevealed(false);
    setPlay(r.data);
  });
  const reveal = () => {
    setRevealed(true);
    if (play) setS(play);
    if (motionOK()) playMoment('tier');
  };
  const disabled = !s.on || s.left <= 0;
  return (
    <section className="pt-card stack rg" aria-labelledby="rg-h" data-testid="rewards-game" data-guide="rewards-game" data-portal={portal}>
      <div className="rg__head">
        <div>
          <p className="pu-eyebrow">Today&apos;s game</p>
          <h2 className="d4" id="rg-h">Play for Rewards points</h2>
        </div>
        <p className="rg__points" data-testid="rewards-game-points"><b><AnimatedNumber value={points} /></b><small>{shown.has_account ? 'points' : 'points saved'}</small></p>
      </div>
      <ul className="rg__prizes" aria-label="What a game can win">{s.prizes.map((p) => <li key={p.key}>{p.label}</li>)}</ul>
      {play && LAZY[play.game] && !revealed && (() => { const Game = LAZY[play.game]!; return (
        <div className="rg__stage" data-testid="rewards-game-stage" data-game={play.game}>
          <p className="small"><b>{TITLE[play.game] ?? 'Play'}</b>: the prize is already yours, the game shows it.</p>
          <Suspense fallback={<p className="small muted">Loading the game...</p>}>
            <Game prize={{ ...play.prize, min_days: null } as never} prizes={s.prizes} reduced={reduced} onReveal={reveal} />
          </Suspense>
          <button type="button" className="btn btn--quiet btn--sm" onClick={reveal} data-testid="rewards-game-skip">Skip to my prize</button>
        </div>
      ); })()}
      {play && revealed && (
        <div className="rg__won" role="status" data-testid="rewards-game-won">
          <p className="d3">+{play.prize.points.toLocaleString('en-CA')} points</p>
          <p className="small">{play.credited ? 'Added to your points.' : pointsWhere(play, portal)}</p>
        </div>
      )}
      {(!play || revealed) && (
        <div className="row">
          <button type="button" className="btn btn--primary" onClick={go} disabled={disabled || busy} aria-busy={busy || undefined} aria-describedby="why-rewards-game" data-testid="rewards-game-play">
            {s.played_today > 0 && s.left > 0 ? 'Play again' : 'Play now'}
          </button>
          <WhyDisabled id="why-rewards-game" why={!s.on ? 'The games are off for now' : s.left <= 0 ? 'Come back tomorrow' : null} />
        </div>
      )}
      <p className="small muted" data-testid="rewards-game-line">{gameLine(s)}</p>
      {error && <p className="alert alert--warn" role="alert" data-testid="rewards-game-error"><span>{error}</span></p>}
      <p className="xs muted">{pointsWhere(s, portal)} Points are never cash: they come off a rental charge only, from 500 points.</p>
    </section>
  );
}
