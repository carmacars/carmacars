import { dialWebhook, statusWebhook, voiceWebhook } from '@/server/twilio-call';

// Twilio's callbacks for the site's outbound Call button (migration 0970): voice (the staff member answered: the TwiML that
// connects the customer), dial (the customer leg ended) and status (the staff leg). Each carries our per-call token and,
// with TWILIO_AUTH_TOKEN set, Twilio's signature (src/server/twilio-call.ts).
export const dynamic = 'force-dynamic';

export async function POST(req: Request, ctx: { params: Promise<{ leg: string }> }): Promise<Response> {
  const { leg } = await ctx.params;
  try {
    if (leg === 'voice') return await voiceWebhook(req);
    if (leg === 'dial') return await dialWebhook(req);
    if (leg === 'status') return await statusWebhook(req);
  } catch {
    return new Response('processing failed', { status: 500 });
  }
  return new Response('not found', { status: 404 });
}
