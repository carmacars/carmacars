// The render chain (release 48 AN): one small interface in front of the image models that make a car's standard views
// (features/listing/worker.ts makeR48, through WorkerDeps.angleAi). Providers in order:
//   1. Workers AI image-to-image (Cloudflare, billed in neurons, a free daily allowance): only for a restyle of a real
//      photo already at the asked angle (it keeps the pose; it cannot turn the car), and only on the first try: when the
//      check refuses its result, the next try goes to the next provider;
//   2. Gemini image (Google): only with non-sensitive photos: a check-in or check-out photo (people, plates, a driveway)
//      is never sent to it; with none left it is not asked.
// Each provider says whether it can take the request; the first that answers with a photo wins; a provider that fails
// passes the request on. Pure apart from the providers it is given (the unit test uses fakes).

export type RenderFailure = 'not_enabled' | 'no_subject' | 'quota' | 'limit' | 'off' | 'timeout' | 'unavailable' | 'error' | 'model' | 'refused';
export type RenderOut = { ok: true; bytes: Uint8Array; contentType: string; provider?: string } | { ok: false; reason: string; message: string; provider?: string };
/** `ref`: one of the car's own photos; `sensitive`: a check-in or check-out photo (never sent outside). */
export interface RenderImage { bytes: Uint8Array; contentType: string; ref?: boolean; sensitive?: boolean }
export interface RenderRequest {
  images: RenderImage[]; prompt: string; photoId: string;
  /** the first image is a real photo at the asked angle (a restyle, not a new view) */
  sameAngle?: boolean;
  /** the tries already made of this view (0: the first) */
  tries?: number;
}
export interface RenderProvider {
  readonly name: string;
  can(r: RenderRequest): boolean;
  make(r: RenderRequest): Promise<RenderOut>;
}

/** The first provider that can take the request and makes the photo; else the last provider's failure. */
export async function renderChain(providers: RenderProvider[], r: RenderRequest): Promise<RenderOut> {
  let last: RenderOut = { ok: false, reason: 'not_enabled', message: 'No image model can make this view' };
  for (const p of providers) {
    if (!p.can(r)) continue;
    const out = await p.make(r).catch((e: unknown): RenderOut => ({ ok: false, reason: 'error', message: e instanceof Error ? e.message : String(e) }));
    if (out.ok) return { ...out, provider: p.name };
    last = { ...out, provider: p.name };
  }
  return last;
}

/** Only the photos that may go to an outside model (no check-in or check-out photo). */
export const nonSensitive = (r: RenderRequest): RenderRequest => ({ ...r, images: r.images.filter((i) => !i.sensitive) });

export const WORKERS_AI_IMG2IMG = '@cf/runwayml/stable-diffusion-v1-5-img2img';

/** Workers AI's answer (the binding's stream or bytes, or the REST API's body) as bytes. */
export async function imageBytes(x: unknown): Promise<Uint8Array | null> {
  if (x instanceof Uint8Array) return x;
  if (x instanceof ArrayBuffer) return new Uint8Array(x);
  if (x && typeof (x as ReadableStream).getReader === 'function') return new Uint8Array(await new Response(x as ReadableStream).arrayBuffer());
  if (x && typeof (x as { image?: unknown }).image === 'string') { // base64 in JSON (some models)
    const bin = atob((x as { image: string }).image); const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  return null;
}

/** Workers AI image-to-image. `run` is the binding's run, or the REST call (server/render-providers.ts). */
export function workersAiRestyle(run: (model: string, input: Record<string, unknown>) => Promise<unknown>, o: { paused?: () => Promise<boolean>; strength?: number } = {}): RenderProvider {
  return {
    name: 'workers-ai',
    can: (r) => !!r.sameAngle && (r.tries ?? 0) === 0 && r.images.length > 0,
    async make(r) {
      if (o.paused && await o.paused()) return { ok: false, reason: 'off', message: 'Workers AI is paused for today' };
      const first = r.images[0]!;
      const raw = await run(WORKERS_AI_IMG2IMG, { prompt: r.prompt.slice(0, 2000), image: [...first.bytes], strength: o.strength ?? 0.45, num_steps: 20, guidance: 7.5 });
      const bytes = await imageBytes(raw);
      if (!bytes || bytes.length < 1000) return { ok: false, reason: 'error', message: 'Workers AI gave no image' };
      return { ok: true, bytes, contentType: 'image/png' };
    }
  };
}

/** Gemini image, given only the non-sensitive photos. `make` is the gated call (server/listing-worker.ts angleAi). */
export function geminiRender(make: (r: RenderRequest) => Promise<RenderOut>): RenderProvider {
  return {
    name: 'gemini',
    // the car's own photos must include one that is not sensitive (a car with no photo of its own: the stock photo path)
    can: (r) => nonSensitive(r).images.length > 0 && (!r.images.some((i) => i.ref) || r.images.some((i) => i.ref && !i.sensitive)),
    make: (r) => make(nonSensitive(r))
  };
}
