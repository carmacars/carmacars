import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { photoUrl } from '@/lib/photo';
import { siteUrl } from '@/lib/site';
import { withUtm } from '@/features/ads/channels';
import { addDays, captionFor, draftCampaign, mondayOf, weekPlan, type Facts, type SocialChannel } from '@/features/ads/social';
import { publishFacebook, publishInstagram, type MetaConfig } from '@/integrations/meta';

// The ads job (migration 0167), from the Worker's cron tick when public.server_jobs_due says "ads" (every 6 hours, or an
// approved post due while Meta publishing is on). The database checks every live ad against its car's rates first (a
// task per ad that no longer matches); then the week's Facebook Page and Instagram drafts are written for this week and the
// next (a day already drafted is left alone); then, only when an Admin has switched Meta publishing on with a token, the
// approved posts that are due go out and each result is recorded. No token is ever logged.
const SR = { role: 'service_role' as const };
export interface SocialRow { id: string; slot_date: string; kind: string; channels: SocialChannel[]; caption: string; link: string | null; photos: string[]; car_code: string | null; posted: Record<string, unknown> }
interface JobData {
  ads_to_update: number; drafts_enabled: boolean; facts: Facts;
  meta: { usable: boolean; page_id: string | null; ig_user_id: string | null; graph_version: string; token: string | null };
  due: SocialRow[];
}

/** A photo path as a public address (Meta fetches it). */
export const publicPhoto = (p: string) => { const u = photoUrl(p); return /^https?:\/\//.test(u) ? u : `${siteUrl()}${u.startsWith('/') ? '' : '/'}${u}`; };

export async function publishDraft(cfg: MetaConfig, d: SocialRow, f: typeof fetch = fetch): Promise<Array<{ channel: SocialChannel; ok: boolean; post_id?: string; url?: string | null; error?: string }>> {
  const out: Array<{ channel: SocialChannel; ok: boolean; post_id?: string; url?: string | null; error?: string }> = [];
  const image = d.photos[0] ? publicPhoto(d.photos[0]) : null;
  for (const ch of d.channels) {
    if (d.posted?.[ch]) continue;
    const tracked = d.link ? withUtm(d.link, ch, 'social', draftCampaign(d)) : null;
    const text = captionFor(d.caption, ch, d.link, tracked);
    try {
      const r = ch === 'instagram' ? await publishInstagram(cfg, { caption: text, imageUrl: image }, f) : await publishFacebook(cfg, { message: text, link: tracked, imageUrl: image }, f);
      out.push({ channel: ch, ok: true, post_id: r.postId, url: r.url });
    } catch (e) {
      out.push({ channel: ch, ok: false, error: e instanceof Error ? e.message : 'Meta refused the post' });
    }
  }
  return out;
}

export async function runAdsJob(f: typeof fetch = fetch): Promise<Record<string, number>> {
  const r = (await rpc('server_ads_job', {}, SR)) as unknown as JobData;
  let added = 0, published = 0, failed = 0;
  if (r.drafts_enabled && r.facts) {
    const mon = mondayOf(r.facts.today);
    for (const w of [mon, addDays(mon, 7)]) {
      const drafts = weekPlan(r.facts, w);
      if (drafts.length) added += Number(await rpc('server_social_drafts_put', { p: { drafts } as unknown as Json }, SR)) || 0;
    }
  }
  if (r.meta?.usable && r.meta.token && r.meta.page_id) {
    const cfg: MetaConfig = { pageId: r.meta.page_id, igUserId: r.meta.ig_user_id, token: r.meta.token, version: r.meta.graph_version };
    for (const d of r.due ?? []) {
      for (const x of await publishDraft(cfg, d, f)) {
        if (x.ok) published++; else failed++;
        await rpc('server_social_published', { p: { id: d.id, ...x } as unknown as Json }, SR);
      }
    }
  }
  return { ads_to_update: r.ads_to_update ?? 0, drafts_added: added, published, failed };
}
