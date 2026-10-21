// Cars put on or taken off the site in the database alone (the automatic publishing of 0070 by pg_cron, a slug changed
// by the search copy, a car deleted, an end-to-end fixture) are not followed by the app rebuilding the fleet page, home,
// the model pages and the sitemaps, so those kept linking a car that was gone (the SEO audit and the crawl of the deploy
// run of October 21, 2026: "/cars/...: HTTP 308", "HTTP 404"). The fleet's signature is the list of the cars the fleet
// page shows (slug and model page); when it changes, the public pages are rebuilt (/api/jobs/public-rebuild): from the
// Worker's cron tick on Cloudflare (custom-worker.ts, one PostgREST call, the last signature in the tag store) and from
// scripts/serve.mjs locally. No imports: it runs in the Worker entry and in Node.

export const FLEET_SIG_KEY = 'carmacars/fleet-sig';

/** A 32-bit FNV-1a hash of the fleet's cars (slug and model page), order-free; never 0 (0 means "none kept"). */
export function signatureOf(rows: ReadonlyArray<{ slug?: unknown; model_hub_path?: unknown }>): number {
  const text = rows.map((r) => `${String(r.slug ?? '')}|${String(r.model_hub_path ?? '')}`).sort().join('\n') + `\n#${rows.length}`;
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h || 1;
}

/** The fleet's signature read through PostgREST (public.fleet, as the fleet page reads it), or null when it cannot be read. */
export async function fleetSignature(env: Record<string, unknown>, f: typeof fetch = fetch): Promise<number | null> {
  const url = env.NEXT_PUBLIC_SUPABASE_URL, key = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (env.DATA_BACKEND !== 'supabase' || typeof url !== 'string' || typeof key !== 'string' || !url || !key) return null;
  try {
    const r = await f(`${url.replace(/\/$/, '')}/rest/v1/rpc/fleet`, {
      method: 'POST', headers: { apikey: key, authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      body: JSON.stringify({ p_filters: {} }), signal: AbortSignal.timeout(5000)
    });
    if (!r.ok) return null;
    const rows = (await r.json()) as unknown;
    return Array.isArray(rows) ? signatureOf(rows as Array<{ slug?: unknown; model_hub_path?: unknown }>) : null;
  } catch {
    return null;
  }
}
