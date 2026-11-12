// Release 42: where the site runs (docs/hosting/off-cloudflare.md). One place asks for what Cloudflare gives a Worker
// through bindings (Workers AI, the service binding to itself, the deployment's version, the Email Service binding) and
// answers with the Node equivalent on the company's server:
//   HOSTING_TARGET unset or `cloudflare`  the Worker's bindings (getCloudflareContext), as before release 42
//   HOSTING_TARGET=node                   `next build` standalone under Node (infra/vps/web): no binding is ever asked for
// No imports besides the lazy Cloudflare one: this runs in the app, in Node scripts and in the unit test.

export type HostingTarget = 'cloudflare' | 'node';
type Env = Record<string, string | undefined>;
type Fetch = typeof fetch;

export interface AiBinding { run(model: string, input: Record<string, unknown>, options?: Record<string, unknown>): Promise<unknown> }
export interface SelfFetcher { fetch(r: Request): Promise<Response> }
export interface EmailBinding { send(m: Record<string, unknown>): Promise<unknown> }

/** The hosting target: `node` only when HOSTING_TARGET says so (anything else is Cloudflare, the default). */
export function hostingTarget(e: Env = process.env): HostingTarget {
  return (e.HOSTING_TARGET ?? '').trim().toLowerCase() === 'node' ? 'node' : 'cloudflare';
}

type Loader = () => Promise<Record<string, unknown> | null>;
const loadCloudflare: Loader = async () => {
  const { getCloudflareContext } = await import('@opennextjs/cloudflare');
  return (await getCloudflareContext({ async: true })).env as unknown as Record<string, unknown>;
};

/** The Worker's bindings, or null on Node and anywhere else there is no Worker (a local server, a test). Never throws. */
export async function cloudflareEnv(e: Env = process.env, load: Loader = loadCloudflare): Promise<Record<string, unknown> | null> {
  if (hostingTarget(e) === 'node') return null;
  try { return (await load()) ?? null; } catch { return null; }
}

// ------------------------------------------------------------------ Workers AI
/** Workers AI over its REST API: the same models and the same daily free neurons as the binding, from any server.
 *  A refusal throws with Cloudflare's code and message, which the callers already read (4006: the day's free
 *  allocation is used up; 429 and 3036: rate limited). */
export function restAi(accountId: string, token: string, f: Fetch = fetch): AiBinding {
  return {
    async run(model: string, input: Record<string, unknown>): Promise<unknown> {
      const r = await f(`https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/ai/run/${model}`, {
        method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(input)
      });
      const j = (await r.json().catch(() => null)) as { success?: boolean; result?: unknown; errors?: Array<{ code?: number; message?: string }> } | null;
      if (!r.ok || !j || j.success === false) {
        const errs = (j?.errors ?? []).map((x) => `${x.code ?? ''} ${x.message ?? ''}`.trim()).filter(Boolean).join('; ');
        throw new Error(`Workers AI ${r.status}${errs ? `: ${errs}` : ''}`.slice(0, 300));
      }
      return j.result;
    }
  };
}

/** Workers AI: the Worker's binding on Cloudflare; on Node the REST API when the account id and a token are set
 *  (CLOUDFLARE_ACCOUNT_ID, WORKERS_AI_API_TOKEN); null when neither is there (the callers then use their fake). */
export async function aiBinding(e: Env = process.env, load: Loader = loadCloudflare, f: Fetch = fetch): Promise<AiBinding | null> {
  const ai = (await cloudflareEnv(e, load))?.AI as AiBinding | undefined;
  if (ai && typeof ai.run === 'function') return ai;
  const acc = e.CLOUDFLARE_ACCOUNT_ID?.trim(), token = e.WORKERS_AI_API_TOKEN?.trim();
  return hostingTarget(e) === 'node' && acc && token ? restAi(acc, token, f) : null;
}

// ------------------------------------------------------------------ the site calling itself
/** The address a request to the site itself goes to on Node: the same path on INTERNAL_ORIGIN (the app's own port on
 *  the server, e.g. http://127.0.0.1:3000) when set, so a job never leaves the machine; unchanged without it. */
export function internalUrl(url: string, e: Env = process.env): string {
  const inner = e.INTERNAL_ORIGIN?.trim();
  if (!inner) return url;
  try {
    const u = new URL(url), o = new URL(inner);
    u.protocol = o.protocol; u.host = o.host;
    return u.toString();
  } catch { return url; }
}

/** A fetcher for the site's own routes (the PDF and Drive import jobs start their next step with it): the Worker's
 *  service binding on Cloudflare, so each run is its own invocation; a plain request on Node. */
export async function selfFetcher(e: Env = process.env, load: Loader = loadCloudflare, f: Fetch = fetch): Promise<SelfFetcher> {
  const self = (await cloudflareEnv(e, load))?.WORKER_SELF_REFERENCE as SelfFetcher | undefined;
  if (self && typeof self.fetch === 'function') return self;
  return { fetch: (r: Request) => f(new Request(internalUrl(r.url, e), r)) };
}

// ------------------------------------------------------------------ the rest
/** Cloudflare Email Service's binding; null on Node (the outbox then sends through its other providers). */
export async function emailBinding(e: Env = process.env, load: Loader = loadCloudflare): Promise<EmailBinding | null> {
  const b = (await cloudflareEnv(e, load))?.EMAIL as EmailBinding | undefined;
  return b && typeof b.send === 'function' ? b : null;
}

/** This deployment's id: the Worker version on Cloudflare, DEPLOY_VERSION (the commit the image was built from) on Node. */
export async function deploymentId(e: Env = process.env, load: Loader = loadCloudflare): Promise<string | null> {
  const v = (await cloudflareEnv(e, load))?.CF_VERSION_METADATA as { id?: unknown } | undefined;
  if (v && typeof v.id === 'string' && v.id) return v.id;
  return hostingTarget(e) === 'node' ? e.DEPLOY_VERSION?.trim() || null : null;
}

export type StorageProvider = 'r2' | 'r2-binding' | 'supabase' | 'local';
/** The file storage that can work on this target: R2's bindings exist only in a Worker, so on Node `r2-binding` becomes
 *  `r2` (the same buckets over R2's S3 API) when its keys are set, and is refused in plain words when they are not. */
export function storageProviderFor(provider: StorageProvider, e: Env = process.env): StorageProvider {
  if (provider !== 'r2-binding' || hostingTarget(e) !== 'node') return provider;
  if (e.R2_ACCOUNT_ID && e.R2_ACCESS_KEY_ID && e.R2_SECRET_ACCESS_KEY) return 'r2';
  throw new Error('STORAGE_PROVIDER=r2-binding needs a Cloudflare Worker. On the server set STORAGE_PROVIDER=supabase, or r2 with R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY (docs/hosting/off-cloudflare.md).');
}
