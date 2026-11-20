// App lock: Face ID, fingerprint or the phone's passcode when the app comes back after a while. No imports.
export const LOCK_AFTER_MS = 5 * 60_000;
export interface LockState { enabled: boolean; signedIn: boolean; locked: boolean; backgroundAt: number | null }

/** The app went to the background: remember when. */
export const onBackground = (s: LockState, now: number): LockState => ({ ...s, backgroundAt: s.backgroundAt ?? now });
/** The app came back, or started (coldStart): locked when the lock is on, someone is signed in, and it was away long enough. */
export function onForeground(s: LockState, now: number, coldStart = false): LockState {
  const away = s.backgroundAt === null ? 0 : now - s.backgroundAt;
  const lock = s.enabled && s.signedIn && (coldStart || s.locked || away >= LOCK_AFTER_MS || away < 0);
  return { ...s, locked: lock, backgroundAt: null };
}
export const onUnlocked = (s: LockState): LockState => ({ ...s, locked: false, backgroundAt: null });
