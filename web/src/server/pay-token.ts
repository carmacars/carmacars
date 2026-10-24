// The token of a pay link (0129): 32 random bytes, URL-safe. The database keeps only its SHA-256, so a link is shown once
// (texted, emailed, or opened on the staff device) and cannot be read back from the database.
export function newPayToken(): string {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function payTokenHash(token: string): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

/** A token as the pay page accepts it: the URL-safe alphabet, 20 to 64 characters. */
export const isPayToken = (t: string) => /^[A-Za-z0-9_-]{20,64}$/.test(t);
