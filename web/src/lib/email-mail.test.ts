import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bindingMessage, mailProblem } from './email-mail.ts';

// Release 23 (0222): the outbox email handed to Cloudflare Email Service.
test('cloudflare email: one recipient, a subject and both bodies; the attachments as the binding takes them', () => {
  const m = { from: 'CarmaCars <hello@example.test>', to: 'renter@example.test', subject: 'Hi', html: '<p>Hi</p>', text: 'Hi', reply_to: 'help@example.test',
    attachments: [{ filename: 'a.pdf', content: 'AAA=', content_type: 'application/pdf' }] };
  assert.equal(mailProblem(m), null);
  assert.equal(mailProblem({ ...m, to: 'nobody' }), 'the recipient');
  assert.equal(mailProblem(null), 'no message');
  const b = bindingMessage(m) as { replyTo: string; attachments: Array<{ type: string }> };
  assert.equal(b.replyTo, 'help@example.test');
  assert.equal(b.attachments[0]!.type, 'application/pdf');
});
