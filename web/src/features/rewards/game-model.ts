// r50 hotfix 2 (5151): the game inside Rewards, as the database returns it (public.server_rewards_game). Pure: the card
// and the unit test share the words.
export type GamePortal = 'renter' | 'owner' | 'staff';
export interface GamePrize { key: string; short: string; label: string; points: number; note: string }
export interface GameState { on: boolean; cap: number; played_today: number; left: number; test: boolean; has_account: boolean; balance: number | null; waiting: number; won_total: number;
  prizes: GamePrize[]; recent: Array<{ at: string; game: string; points: number }> }
export interface GamePlay extends GameState { id: string; game: string; prize: GamePrize; credited: boolean }

/** The line under the Play button. */
export function gameLine(s: Pick<GameState, 'on' | 'left' | 'cap'>): string {
  if (!s.on) return 'The games are off for now.';
  if (s.left <= 0) return s.cap === 1 ? 'You played today\'s game. Come back tomorrow for another.' : `You played all ${s.cap} games today. Come back tomorrow.`;
  return s.cap === 1 ? 'One game a day. Every game wins points.' : `${s.left} of ${s.cap} games left today. Every game wins points.`;
}

/** Where the points went, in the viewer's words. */
export function pointsWhere(s: Pick<GameState, 'has_account' | 'waiting' | 'test'>, portal: GamePortal): string {
  if (s.test) return 'A test account plays, but earns no points.';
  if (s.has_account) return 'Your points are on your CarmaCars Rewards account: use them off your next rental charge.';
  return `${s.waiting.toLocaleString('en-CA')} points are saved for you. They move to your Rewards account by themselves when you ${portal === 'renter' ? 'send your first request' : 'rent a car with us (sign in and send a request)'}.`;
}
