import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { jobAuthorized } from '@/server/job-auth';
import { env } from '@/lib/env';
import { localConf } from '@/integrations/ai/links';
import { localReady } from '@/integrations/ai/ollama';

// r48 part AI (migration 3095): every five minutes on the company's server (scripts/vps-server.mjs, only when a local model
// is configured): which of the server's own models answer now (text, vision, speech), recorded for the database. While one
// is ready, the AI gates (app.ai_allow) let its features run past Workers AI's daily allowance, and Settings > Usage shows
// "ready" or "warming up". A status older than 15 minutes counts as not ready.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const c = localConf();
  const s = await localReady(c);
  await rpc('server_ai_local_status' as never, { p: { text_ready: s.text, vision_ready: s.vision, stt_ready: s.stt, text_model: s.textModel, vision_model: s.visionModel,
    stt_model: s.sttModel, detail: s.detail, gemini_ready: !!env().GEMINI_API_KEY?.trim() } as unknown as Json } as never, SR);
  return NextResponse.json({ ok: true, ...s });
}
