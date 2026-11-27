import { env } from '@/lib/env';
import { pickOrigin } from './origin-pick';

// The address the browser used, for an absolute address that must reach it (an OAuth redirect_uri, a link). Behind Caddy
// req.url reads http://localhost:3000, so the host comes from x-forwarded-host and x-forwarded-proto (set by
// scripts/vps-server.mjs), then from NEXT_PUBLIC_APP_URL. A same-site redirect needs no origin: use localRedirect(path).
export function publicOrigin(req: Request): string {
  return pickOrigin(req.headers.get('x-forwarded-host'), req.headers.get('x-forwarded-proto'), env().NEXT_PUBLIC_APP_URL);
}
