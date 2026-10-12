import type { EmailAdapter } from './types';

export function resendEmail(apiKey: string): EmailAdapter {
  return {
    name: 'resend',
    async send(m) {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}`, 'content-type': 'application/json', 'Idempotency-Key': m.idempotencyKey },
        body: JSON.stringify({ from: m.from, to: [m.to], reply_to: m.replyTo, subject: m.subject, html: m.html, text: m.text, headers: m.headers })
      });
      if (!r.ok) throw new Error(`Resend refused the message (${r.status}): ${await r.text()}`);
      return (await r.json()) as { id: string };
    }
  };
}
