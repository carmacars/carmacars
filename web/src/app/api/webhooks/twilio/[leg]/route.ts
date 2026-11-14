import { clientWebhook, dialWebhook, incomingWebhook, recordingWebhook, ringEndWebhook, statusWebhook, voiceWebhook } from '@/server/twilio-call';

// Twilio's callbacks (migration 0970): voice (the staff member answered: the TwiML that connects the customer), dial (the
// customer leg ended) and status (the staff leg). 1880: recording (the customer leg's recording). r44 (2790): client (a call
// placed in the browser, the TwiML App's Voice URL), incoming (the business number's Voice URL: the browsers of the staff
// online ring) and ring-end (answered or missed). Every one is checked against Twilio's signature with TWILIO_AUTH_TOKEN,
// and the legs of one call also carry our per-call token (src/server/twilio-call.ts).
export const dynamic = 'force-dynamic';

const LEGS: Record<string, (req: Request) => Promise<Response>> = {
  voice: voiceWebhook, dial: dialWebhook, status: statusWebhook, recording: recordingWebhook,
  client: clientWebhook, incoming: incomingWebhook, 'ring-end': ringEndWebhook,
};

export async function POST(req: Request, ctx: { params: Promise<{ leg: string }> }): Promise<Response> {
  const { leg } = await ctx.params;
  const run = Object.hasOwn(LEGS, leg) ? LEGS[leg] : undefined;
  if (!run) return new Response('not found', { status: 404 });
  try {
    return await run(req);
  } catch {
    return new Response('processing failed', { status: 500 });
  }
}
