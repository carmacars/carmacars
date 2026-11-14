// r47: a page's metadata never fails the page. Next 16 streams metadata to browsers after the page itself, so a
// generateMetadata whose read failed (the database busy, a cold Worker with no kept copy of the settings) reached the
// browser as React error #441 on any page: every route's metadata runs the root layout's, and the place and landing
// pages read the page, the tokens and the settings again. A failed read now gives plain metadata (the title only);
// Next's own signals (not found, redirect, dynamic use) still pass through. No imports: unit tested in Node.
import type { Metadata } from 'next';

/** Next's control-flow throws (notFound, redirect, permanentRedirect, a dynamic API at build): never swallowed. */
export function isNextSignal(e: unknown): boolean {
  const d = (e as { digest?: unknown } | null)?.digest;
  return typeof d === 'string' && /^(NEXT_|DYNAMIC_SERVER_USAGE|BAILOUT_TO_CLIENT_SIDE_RENDERING)/.test(d);
}

/** The metadata `read` gives, or `fallback` when it throws anything but a Next signal. */
export async function metaOr(read: () => Promise<Metadata>, fallback: Metadata, log: (m: string) => void = () => undefined): Promise<Metadata> {
  try {
    return await read();
  } catch (e) {
    if (isNextSignal(e)) throw e;
    log(`metadata fell back: ${e instanceof Error ? e.message.slice(0, 160) : String(e).slice(0, 160)}`);
    return fallback;
  }
}

/** A readable title for a path when nothing could be read: "/car-rental/limo-service/saipan-mp" -> "Limo service, saipan mp | CarmaCars". */
export function titleFromPath(path: string, brand = 'CarmaCars'): string {
  const parts = (path.split('?')[0] ?? '').split('/').filter(Boolean).slice(-2).map((p) => decodeURIComponent(p).replace(/[-_]+/g, ' ').trim()).filter(Boolean);
  if (!parts.length) return brand;
  const t = parts.map((p, i) => (i === 0 ? p.charAt(0).toUpperCase() + p.slice(1) : p)).join(', ');
  return `${t} | ${brand}`;
}
