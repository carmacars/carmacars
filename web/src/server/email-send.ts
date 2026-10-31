import 'server-only';
import { linkSecret } from '@/server/links';

// Cloudflare Email Service for the outbox (migration 0222, docs/changes/2026-11-03-cloudflare-email.md). The send-outbox
// Edge Function posts each rendered email to /api/email/send with this token (HMAC of a fixed label with
// LINK_SIGNING_KEY, the same key it signs file links with); the route sends it with the Worker's EMAIL binding.
export async function emailSendToken(): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(linkSecret()), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode('carmacars-email-send-v1')));
  return Array.from(mac, (b) => b.toString(16).padStart(2, '0')).join('');
}

export { bindingMessage, mailProblem, type OutboxMail } from '@/lib/email-mail';
