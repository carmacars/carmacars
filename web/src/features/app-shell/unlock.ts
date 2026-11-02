// Face ID and fingerprint unlock in the store app (migration 0390): the switch is kept on the phone (the app's own
// store, Capacitor Preferences), never on the server, so it belongs to this phone only. No imports: the shell, the
// profile card and the unit tests share it.

/** The phone's own setting: '1' when unlock is on. */
export const UNLOCK_KEY = 'cc.unlock';
/** Back in the app after this long away: Face ID or the fingerprint again. */
export const UNLOCK_AFTER_MS = 5 * 60_000;

/** The app came back to the front: ask again when it was away at least this long (or the time is unknown). */
export function lockDue(awayAt: number | null, now: number, after = UNLOCK_AFTER_MS): boolean {
  return awayAt === null ? false : now - awayAt >= after;
}
