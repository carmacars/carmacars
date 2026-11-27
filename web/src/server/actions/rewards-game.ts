'use server';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import type { GamePortal, GamePlay } from '@/features/rewards/game-model';

// r50 hotfix 2 (5151): the game inside Rewards. The signed-in user comes from the session, never from the browser; the
// database checks the portal, the day's plays, draws the prize and credits the points (public.server_rewards_game).
const SR = { role: 'service_role' as const };
type R<T> = { ok: true; data: T } | { ok: false; message: string };

export async function rewardsGamePlay(portal: GamePortal): Promise<R<GamePlay>> {
  try {
    const user = await currentUser();
    if (!user) return { ok: false, message: 'Sign in first.' };
    const data = (await rpc('server_rewards_game' as never, { p_by: user.id, p_action: 'play', p: { portal } } as never, SR)) as unknown as GamePlay;
    return { ok: true, data };
  } catch (e) { return { ok: false, message: (e as Error).message || 'The game could not start. Try again.' }; }
}
