import { rewardsGameState } from '@/server/rewards-game';
import type { GamePortal } from './game-model';
import { RewardsGameClient } from './RewardsGameClient';
import '@/features/games/games.css';

// r50 hotfix 2 (5151): the discount games inside Rewards for renters, owners and staff, for points. The card reads its
// state on the server (no blank first paint); the game itself loads when Play is pressed.
export async function RewardsGame({ userId, portal }: { userId: string; portal: GamePortal }) {
  const s = await rewardsGameState(userId, portal);
  if (!s) return null;
  return <RewardsGameClient portal={portal} initial={s} />;
}
