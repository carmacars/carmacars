import 'server-only';
import { geminiRender, workersAiRestyle, type RenderOut, type RenderProvider, type RenderRequest } from '@/integrations/renders/chain';

// r48 AN: the render chain's providers on this host (integrations/renders/chain.ts). Workers AI: the Worker's AI binding on
// Cloudflare, or Workers AI's REST API on the company server (CLOUDFLARE_ACCOUNT_ID, WORKERS_AI_API_TOKEN), behind the
// usage guard (nothing is asked while Workers AI is paused for the day); neither: Gemini only. Gemini: the gated call the
// worker already makes (server_showroom_ai_gate: the image model's daily limit less the reserve).
async function workersAiRun(): Promise<((model: string, input: Record<string, unknown>) => Promise<unknown>) | null> {
  const acc = process.env.CLOUDFLARE_ACCOUNT_ID?.trim(), token = process.env.WORKERS_AI_API_TOKEN?.trim();
  if (acc && token) {
    // the image models answer with the image itself (not JSON), so not through runtime.ts's restAi
    return async (model, input) => {
      const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(acc)}/ai/run/${model}`, {
        method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(input), signal: AbortSignal.timeout(60_000)
      });
      if (!r.ok) throw new Error(`Workers AI ${r.status}`);
      return new Uint8Array(await r.arrayBuffer());
    };
  }
  try {
    const ai = await (await import('@/lib/platform/runtime')).aiBinding();
    return ai ? (model, input) => ai.run(model, input) : null;
  } catch { return null; }
}

export async function renderProviders(gemini: (r: RenderRequest) => Promise<RenderOut>): Promise<RenderProvider[]> {
  const run = await workersAiRun();
  const out: RenderProvider[] = [];
  if (run) {
    const { aiRoom } = await import('@/integrations/ai/paused');
    out.push(workersAiRestyle(run, { paused: () => aiRoom.paused() }));
  }
  out.push(geminiRender(gemini));
  return out;
}
