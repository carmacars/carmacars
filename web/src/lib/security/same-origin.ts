// The per-route check behind the Worker's own (request-guard.ts): a write that names another site in its Origin header is
// refused. No imports. An Origin that cannot be read as an address ("null", junk) counts as another site and is refused
// too, never an error: `new URL()` on it throws, and a thrown error was a 500 instead of the 403.
export function foreignOrigin(origin: string | null | undefined, host: string | null | undefined): boolean {
  if (!origin) return false;
  try { return new URL(origin).host !== host; } catch { return true; }
}

/** Two secrets compared without stopping at the first different character (a bearer token against the expected one). */
export function sameSecret(got: string, want: string): boolean {
  let d = got.length ^ want.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}
