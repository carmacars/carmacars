// Contact capture (migration 0090): which typed values are worth saving, the same rules as the database's
// app.capture_clean_* (a name of 2 to 120 characters, an email address, a phone number of 10 to 15 digits). Pure, so the
// browser, the server and the unit tests share it.
export const CAPTURE_FORMS = ['booking_request', 'owner_application', 'contact', 'owner_lead', 'chat', 'game', 'signup'] as const;
export type CaptureForm = (typeof CAPTURE_FORMS)[number];
export interface CaptureFields { name?: string; email?: string; phone?: string }
export interface CaptureReply {
  ok: boolean;
  state?: 'phone_only' | 'new' | 'this_device' | 'existing' | 'signed_in' | null;
  linkSent?: boolean;
  linkSentBefore?: boolean;
  rateLimited?: boolean;
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/;

export function cleanName(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().replace(/\s+/g, ' ');
  return s.length >= 2 && s.length <= 120 ? s : undefined;
}
export function cleanEmail(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().toLowerCase();
  return s.length <= 200 && EMAIL.test(s) ? s : undefined;
}
export function cleanPhone(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const d = v.replace(/\D/g, '');
  return d.length >= 10 && d.length <= 15 ? v.trim().slice(0, 40) : undefined;
}
/** Only the valid fields, so a half-typed value is never saved. */
export function cleanFields(f: { name?: unknown; email?: unknown; phone?: unknown }): CaptureFields {
  const out: CaptureFields = {};
  const n = cleanName(f.name), e = cleanEmail(f.email), p = cleanPhone(f.phone);
  if (n) out.name = n;
  if (e) out.email = e;
  if (p) out.phone = p;
  return out;
}

/** The line shown under the form after a save, or null (nothing to say). Never says more about an existing account
 *  than that it exists and a sign-in link went (or can be had). */
export function captureNote(r: CaptureReply | null): { tone: 'ok' | 'info'; text: string; signIn?: boolean } | null {
  if (!r || !r.ok) return null;
  // release 37: sign-in is offered on the spot every time (Google, Apple, a texted code or the password), not only later
  if (r.state === 'new') return { tone: 'ok', text: 'Saved as you type. We opened an account for you with this email: finish any time on this device, and confirm it with the link we will email you. Or sign in now to carry on from any device.', signIn: true };
  if (r.state === 'existing' && r.linkSent) return { tone: 'info', text: 'You have an account: we sent you a sign-in link, or sign in now.', signIn: true };
  if (r.state === 'existing') return { tone: 'info', text: 'You have an account: sign in to continue, or use the link we emailed you.', signIn: true };
  return null;
}

/** The reply the form keeps after a save. A form that gets its draft after the first save sends the same values again
 *  (useCapture's relink) and the database answers "this_device": that is the account this browser has just opened, so the
 *  note about it stays (it used to vanish about a second after it appeared). A failed save changes nothing shown. */
export function keepReply(prev: CaptureReply | null, next: CaptureReply): CaptureReply {
  if (prev?.ok && prev.state === 'new' && (!next.ok || next.state === 'this_device')) return prev;
  return next;
}
