// The native app's sign-out (r48 security audit, migration 3400). The app's access tokens are checked with the
// project's public keys, without asking the sign-in service, so a token would stay good until it expires after
// "Sign out". On sign-out the server stores the token's keys (public.server_bearer_revoke) and every call refuses a token
// whose keys are stored: "t:" the SHA-256 of the token, "s:" its sign-in session (Supabase's session_id claim), so the
// session's other tokens end with it. The token itself is never stored.
const SID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function revocationKeys(token: string, claims: Record<string, unknown> | null): Promise<string[]> {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)));
  const keys = [`t:${[...d].map((b) => b.toString(16).padStart(2, '0')).join('')}`];
  const sid = claims?.session_id;
  if (typeof sid === 'string' && SID.test(sid)) keys.push(`s:${sid.toLowerCase()}`);
  return keys;
}

/** Tokens just checked and found live, kept a few seconds so a burst of calls asks the database once. A token signed
 *  out on this server is dropped at once; on another server it ends within `ttlMs`. */
export class LiveTokens {
  private seen = new Map<string, number>();
  private ttlMs: number;
  private max: number;
  constructor(ttlMs = 15_000, max = 2000) { this.ttlMs = ttlMs; this.max = max; }
  has(key: string, now = Date.now()): boolean {
    const at = this.seen.get(key);
    if (at === undefined) return false;
    if (now - at >= this.ttlMs) { this.seen.delete(key); return false; }
    return true;
  }
  add(key: string, now = Date.now()): void {
    if (this.seen.size >= this.max) this.seen.clear();
    this.seen.set(key, now);
  }
  drop(key: string): void { this.seen.delete(key); }
}
