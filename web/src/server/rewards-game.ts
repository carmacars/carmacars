import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { GamePortal, GameState } from '@/features/rewards/game-model';

// r50 hotfix 2 (5151): the Rewards game card's state for a server page (never a server action: the user id comes from
// the page's own session check).
export async function rewardsGameState(userId: string, portal: GamePortal): Promise<GameState | null> {
  return (await rpc('server_rewards_game' as never, { p_by: userId, p_action: 'state', p: { portal } } as never, { role: 'service_role' }).catch(() => null)) as unknown as GameState | null;
}
