// Publishing to the CarmaCars Facebook Page and Instagram professional account through Meta's Graph API (migration 0167).
// Off until an Admin enters the Page id, the Instagram account id and a Page access token in Admin > Settings > Meta
// publishing (the token is kept in Supabase Vault). Nothing here runs before that: the ads job asks the database first and
// gets no token while it is off. Facebook: a photo post (/{page}/photos) or a link post (/{page}/feed). Instagram: a media
// container (/{ig}/media with a public image address) then /{ig}/media_publish, then the permalink. One photo per post (the
// first of the draft); a carousel is posted by hand. Relative imports only: the unit tests run it in Node with a fake fetch.

export interface MetaConfig { pageId: string; igUserId: string | null; token: string; version: string }
export interface Published { postId: string; url: string | null }

const GRAPH = 'https://graph.facebook.com';

async function call(f: typeof fetch, cfg: MetaConfig, path: string, params: Record<string, string>, method: 'POST' | 'GET' = 'POST'): Promise<Record<string, unknown>> {
  const body = new URLSearchParams({ ...params, access_token: cfg.token });
  const url = `${GRAPH}/${cfg.version}/${path}`;
  const r = await f(method === 'GET' ? `${url}?${body}` : url, method === 'GET'
    ? { method, signal: AbortSignal.timeout(20_000) }
    : { method, headers: { 'content-type': 'application/x-www-form-urlencoded' }, body, signal: AbortSignal.timeout(20_000) });
  const d = (await r.json().catch(() => ({}))) as Record<string, unknown> & { error?: { message?: string; code?: number } };
  if (!r.ok || d.error) throw new Error(`Meta: ${d.error?.message ?? `HTTP ${r.status}`}`.slice(0, 300));
  return d;
}

/** A post on the Facebook Page: with a photo when there is one, else the text and the link. */
export async function publishFacebook(cfg: MetaConfig, p: { message: string; link: string | null; imageUrl: string | null }, f: typeof fetch = fetch): Promise<Published> {
  if (p.imageUrl) {
    const d = await call(f, cfg, `${cfg.pageId}/photos`, { url: p.imageUrl, caption: p.message, published: 'true' });
    const id = String(d.post_id ?? d.id ?? '');
    return { postId: id, url: id ? `https://www.facebook.com/${id}` : null };
  }
  const d = await call(f, cfg, `${cfg.pageId}/feed`, { message: p.message, ...(p.link ? { link: p.link } : {}) });
  const id = String(d.id ?? '');
  return { postId: id, url: id ? `https://www.facebook.com/${id}` : null };
}

/** A post on Instagram: Instagram needs a photo at a public address. */
export async function publishInstagram(cfg: MetaConfig, p: { caption: string; imageUrl: string | null }, f: typeof fetch = fetch): Promise<Published> {
  if (!cfg.igUserId) throw new Error('Instagram: no Instagram account id is set in Meta publishing');
  if (!p.imageUrl) throw new Error('Instagram: a post needs a photo; add one to the draft or post it by hand');
  const c = await call(f, cfg, `${cfg.igUserId}/media`, { image_url: p.imageUrl, caption: p.caption });
  const done = await call(f, cfg, `${cfg.igUserId}/media_publish`, { creation_id: String(c.id ?? '') });
  const id = String(done.id ?? '');
  let url: string | null = null;
  try { url = (await call(f, cfg, id, { fields: 'permalink' }, 'GET')).permalink as string ?? null; } catch { url = null; }
  return { postId: id, url };
}
