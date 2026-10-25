import 'server-only';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { linkSecret } from '@/server/links';
import { storage } from '@/integrations/storage';
import { feedKey, feedKeyOk, isUuid } from '@/features/partner-crm/feed-key';
import { photoUrls, type OutboundCar } from '@/features/partner-crm/mapping';

// The read-only feed and the widget of a partner link (migration 0147): the same cars as the sync (never a partner car;
// app.partner_crm_outbound_cars decides), behind a key made from LINK_SIGNING_KEY and the link's key version.
const SR = { role: 'service_role' as const };
export interface Feed { partner: string; cars: OutboundCar[]; site: { url: string; name: string }; photos: (c: OutboundCar) => string[] }

export async function loadFeed(partnerId: string, key: string | null): Promise<Feed | null> {
  if (!isUuid(partnerId) || !key) return null;
  const f = (await rpc('server_partner_feed', { p_partner: partnerId }, SR)) as unknown as { feed_version: number; enabled: boolean; partner: string; cars: OutboundCar[]; site: { url: string; name: string } } | null;
  if (!f || !f.enabled || !(await feedKeyOk(linkSecret(), partnerId, f.feed_version, key))) return null;
  const s = await storage();
  const abs = (u: string) => (/^https?:\/\//.test(u) ? u : `${f.site.url}${u.startsWith('/') ? '' : '/'}${u}`);
  return { partner: f.partner, cars: f.cars, site: f.site, photos: (c) => photoUrls(c.photos ?? [], f.site.url, (p) => abs(s.publicUrl(p))) };
}

/** The addresses an Admin hands the partner (Settings > Partners). */
export async function feedLinks(partnerId: string, version: number): Promise<{ json: string; csv: string; widget: string; iframe: string }> {
  const k = await feedKey(linkSecret(), partnerId, version);
  const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
  const widget = `${base}/partner-widget/${partnerId}?key=${k}`;
  return { json: `${base}/partner-feed/${partnerId}?key=${k}&format=json`, csv: `${base}/partner-feed/${partnerId}?key=${k}&format=csv`, widget,
    iframe: `<iframe src="${widget}" title="CarmaCars cars" width="100%" height="900" style="border:0" loading="lazy"></iframe>` };
}
