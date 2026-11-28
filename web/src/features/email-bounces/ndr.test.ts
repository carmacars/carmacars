import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bounceWords, readBounce } from './ndr.ts';

// R51 (5204, REQ-136): bounce emails read into the address that failed, the status, the reason and our reference.
const REF = '0f6c2d3e-1111-4a2b-9c3d-123456789abc';
const dsn = `From: postmaster@insurer.example.test
To: sender@example.test
Subject: Undeliverable: Invoice BS-1001
Content-Type: multipart/report; report-type=delivery-status; boundary="b1"

--b1
Content-Type: text/plain; charset="us-ascii"

Delivery has failed to these recipients or groups:
adjuster@insurer.example.test
The sender isn't on the recipient's list of senders to accept mail from.

--b1
Content-Type: message/delivery-status

Reporting-MTA: dns;mail.insurer.example.test

Final-Recipient: rfc822;adjuster@insurer.example.test
Action: failed
Status: 5.7.129
Diagnostic-Code: smtp;550 5.7.129 RESOLVER.RST.RestrictedToRecipientsPermission; not authorized to send to the
 recipient

--b1
Content-Type: text/rfc822-headers

From: Blind Spot Car Rental <sender@example.test>
To: adjuster@insurer.example.test
X-Outbox-Ref: ${REF}
Message-ID: <cf:abc123@carmacars.ca>
Subject: Invoice BS-1001

--b1--
`;

test('a delivery status report: the failed address, the status, the reason and our reference', () => {
  assert.deepEqual(readBounce(dsn), [{ to: 'adjuster@insurer.example.test', status: '5.7.129',
    reason: '550 5.7.129 RESOLVER.RST.RestrictedToRecipientsPermission; not authorized to send to the recipient', ref: REF, messageId: 'cf:abc123@carmacars.ca' }]);
});

test('an NDR with only text names the address and the server answer', () => {
  const ndr = `From: Mail Delivery System <mailer-daemon@example.test>\nSubject: Delivery Status Notification (Failure)\nContent-Type: text/plain\n\nYour message wasn't delivered to claims@insurer.example.test because the address couldn't be found.\nRemote server returned '550 5.1.1 User unknown'\n`;
  assert.deepEqual(readBounce(ndr), [{ to: 'claims@insurer.example.test', status: '5.1.1', reason: "550 5.1.1 User unknown'", ref: null, messageId: null }]);
});

test('not a bounce: an ordinary email, or a delivery report that says delivered', () => {
  assert.deepEqual(readBounce('From: adjuster@insurer.example.test\nSubject: Re: Invoice\n\nThanks, approved.'), []);
  assert.deepEqual(readBounce(dsn.replace('Status: 5.7.129', 'Status: 2.0.0')), []);
  assert.deepEqual(readBounce(''), []);
});

test('the words for the Admin', () => {
  assert.match(bounceWords({ status: '5.7.129', reason: null }), /accepts only senders on its list/);
  assert.match(bounceWords({ status: '5.1.1', reason: 'User unknown' }), /does not exist/);
  assert.equal(bounceWords({ status: null, reason: null }), 'Their mail server refused it.');
});
