import type { ComponentType } from 'react';
import type { GameKind } from './rules';
import type { GameProps } from './GamePopup';

// The games' code, one small file each, fetched when needed: the site's game card (GamePopup) and the game in Rewards
// (r50 hotfix 2, features/rewards/RewardsGameClient.tsx) load them from here.
export const GAME_LOAD: Record<GameKind, () => Promise<{ default: ComponentType<GameProps> }>> = {
  wheel: () => import('./games/Wheel'), scratch: () => import('./games/Scratch'), blackjack: () => import('./games/Blackjack'),
  cups: () => import('./games/Cups'), plinko: () => import('./games/Plinko'), pack: () => import('./games/Pack'),
  coin: () => import('./games/Coin'), dice: () => import('./games/Dice'), slots: () => import('./games/Slots'), drop: () => import('./games/Drop'),
  mystery: () => import('./games/Mystery')
};
