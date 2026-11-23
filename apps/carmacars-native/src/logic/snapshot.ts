// r49 (the owner's reel 7, app launch speed): the app opens on what it knew last time, then refreshes in the background.
// Two small snapshots kept in the keychain beside the session (src/native.ts): the site's settings for the app, and the
// signed-in account (who, which portals). Nothing is asked of the server before the first screen is drawn when a snapshot
// fits. Each is kept under 2,000 characters (the secure store's comfortable size) and is read back only when it is the
// same shape, not too old, and, for the account, the same person as the session. Pure functions: tested in app.test.ts.

export const SNAPSHOT_VERSION = 1;
/** An older snapshot is not shown: the app waits for the server instead (two weeks). */
export const SNAPSHOT_MAX_MS = 14 * 24 * 60 * 60 * 1000;
export const SNAPSHOT_MAX_CHARS = 2000;

interface Stored<T> { v: number; at: number; uid: string | null; data: T }

/** The text to keep, or null when it is too big to keep (the app then simply waits for the server next time). */
export function packSnapshot<T>(data: T, uid: string | null, now: number): string | null {
  const raw = JSON.stringify({ v: SNAPSHOT_VERSION, at: now, uid, data } satisfies Stored<T>);
  return raw.length > SNAPSHOT_MAX_CHARS ? null : raw;
}

/** What was kept, when it is usable: same version, not older than two weeks, and (when `uid` is given) the same person. */
export function readSnapshot<T>(raw: string | null | undefined, now: number, uid?: string | null): T | null {
  if (!raw) return null;
  let s: Partial<Stored<T>>;
  try { s = JSON.parse(raw) as Partial<Stored<T>>; } catch { return null; }
  if (!s || s.v !== SNAPSHOT_VERSION || typeof s.at !== 'number' || s.data == null) return null;
  if (now - s.at > SNAPSHOT_MAX_MS || s.at > now + 60_000) return null;
  if (uid !== undefined && (s.uid ?? null) !== uid) return null;
  return s.data as T;
}
