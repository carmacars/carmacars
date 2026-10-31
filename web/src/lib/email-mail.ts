// R23 (0222): the outbox email the Worker sends with Cloudflare Email Service (pure: unit tested).
export interface OutboxMail {
  from: string; to: string; reply_to?: string; subject: string; html: string; text: string; headers?: Record<string, string>;
  attachments?: Array<{ filename: string; content: string; content_type: string }>;
}
/** The Email Service binding's message (Workers "send_email" binding, Email Service beta: env.EMAIL.send). */
export function bindingMessage(m: OutboxMail): Record<string, unknown> {
  return {
    to: m.to, from: m.from, subject: m.subject, html: m.html, text: m.text,
    ...(m.reply_to ? { replyTo: m.reply_to } : {}), ...(m.headers ? { headers: m.headers } : {}),
    ...(m.attachments?.length ? { attachments: m.attachments.map((a) => ({ filename: a.filename, content: a.content, type: a.content_type, disposition: 'attachment' })) } : {})
  };
}
/** A mail the route accepts: one recipient, a subject and both bodies. */
export function mailProblem(m: Partial<OutboxMail> | null): string | null {
  if (!m || typeof m !== 'object') return 'no message';
  if (typeof m.to !== 'string' || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(m.to)) return 'the recipient';
  if (typeof m.from !== 'string' || !m.from.includes('@')) return 'the sender';
  if (typeof m.subject !== 'string' || !m.subject.trim()) return 'the subject';
  if (typeof m.html !== 'string' || typeof m.text !== 'string') return 'the body';
  return null;
}
