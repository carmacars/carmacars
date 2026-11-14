// The per-route check behind the Worker's own (request-guard.ts): a write that names another site in its Origin header is
// refused. No imports. An Origin that cannot be read as an address ("null", junk) counts as another site and is refused
// too, never an error: `new URL()` on it throws, and a thrown error was a 500 instead of the 403.
// r44: the same rule as the Worker's guard (request-guard.ts): www. or not is the same site, and an Origin of "null" (sent
// by some in-app browsers, the one a text message's link opens) is this site when the browser says the request is
// same-origin (Sec-Fetch-Site). The renter's "I've returned the car" and accident uploads were refused there.
const bare = (h: string) => h.toLowerCase().replace(/^www\./, '');
export function foreignOrigin(origin: string | null | undefined, host: string | null | undefined, secFetchSite?: string | null): boolean {
  if (!origin) return false;
  if (origin === 'null') return (secFetchSite ?? '').toLowerCase() !== 'same-origin';
  if (!host) return true;
  try { return bare(new URL(origin).host) !== bare(host); } catch { return true; }
}

/** Two secrets compared without stopping at the first different character (a bearer token against the expected one). */
export function sameSecret(got: string, want: string): boolean {
  let d = got.length ^ want.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}
