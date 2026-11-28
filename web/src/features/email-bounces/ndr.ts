// R51 (5204, REQ-136): a bounce email (an NDR or an RFC 3464 delivery status report) read into what failed. Pure: the route
// (app/api/inbound/bounce) passes the raw message; only these fields go to the database, the message is never stored.
import { parseMime } from '../turo/email.ts';

export interface Bounce { to: string; status: string | null; reason: string | null; ref: string | null }

const EMAIL = /[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const isBounceSender = (from: string, subject: string, headers: Record<string, string>): boolean =>
  /mailer-daemon|postmaster|mail delivery (sub)?system/i.test(from)
  || /undeliverable|delivery status notification|returned mail|delivery has failed|failure notice|could not be delivered/i.test(subject)
  || /multipart\/report/i.test(headers['content-type'] ?? '');

/** The bounces in a message (one per failed recipient), or [] when it is not a bounce. */
export function readBounce(raw: string): Bounce[] {
  if (!raw) return [];
  const m = parseMime(raw);
  if (!isBounceSender(m.from, m.subject, m.headers)) return [];
  const src = raw.replace(/\r\n/g, '\n').replace(/=\n/g, '');
  const ref = /^X-Outbox-Ref:\s*([0-9a-f-]{36})\s*$/im.exec(src)?.[1]?.toLowerCase() ?? null;
  const out: Bounce[] = [];
  // RFC 3464: a block per recipient (Final-Recipient, Status, Diagnostic-Code)
  const blocks = src.split(/\n(?=(?:Original|Final)-Recipient:)/i).filter((b) => /^(Final|Original)-Recipient:/i.test(b));
  for (const b of blocks) {
    const to = /^Final-Recipient:\s*(?:rfc822;)?\s*<?([^>\s]+@[^>\s]+)>?/im.exec(b)?.[1] ?? /^Original-Recipient:\s*(?:rfc822;)?\s*<?([^>\s]+@[^>\s]+)>?/im.exec(b)?.[1];
    const status = /^Status:\s*([245]\.\d{1,3}\.\d{1,3})/im.exec(b)?.[1] ?? null;
    if (!to || (status && !status.startsWith('5') && !status.startsWith('4'))) continue;
    if (status?.startsWith('2')) continue;
    const diag = /^Diagnostic-Code:\s*(?:smtp;)?\s*(.+(?:\n[ \t].+)*)/im.exec(b)?.[1]?.replace(/\s+/g, ' ').trim() ?? null;
    out.push({ to: to.toLowerCase(), status, reason: diag ? diag.slice(0, 300) : null, ref });
  }
  if (out.length) return dedupe(out);
  // an NDR without a report part: the text names the address and the server's answer
  const text = m.text || src;
  const code = /\b([45]\d\d)[ -]([45]\.\d{1,3}\.\d{1,3})\b[^\n]*/.exec(text);
  const to = /(?:delivered to|delivery to|to these recipients[^:]*:|recipient(?:s)?:)\s*<?([^\s<>]+@[^\s<>]+)/i.exec(text)?.[1] ?? EMAIL.exec(text.split(/remote server|diagnostic/i)[0] ?? '')?.[0];
  if (!to || !code) return [];
  return [{ to: to.toLowerCase().replace(/[.,;]+$/, ''), status: code[2] ?? null, reason: code[0].replace(/\s+/g, ' ').trim().slice(0, 300), ref }];
}

const dedupe = (xs: Bounce[]) => xs.filter((x, i) => xs.findIndex((y) => y.to === x.to) === i);

/** Words for a refusal an Admin can act on. */
export function bounceWords(b: Pick<Bounce, 'status' | 'reason'>): string {
  const r = `${b.status ?? ''} ${b.reason ?? ''}`;
  if (/5\.7\.129|RestrictedToRecipients|list of senders to accept/i.test(r)) return 'The mailbox accepts only senders on its list: ask the insurer to add our sender address.';
  if (/5\.1\.1|user unknown|does not exist|no such user|recipient not found/i.test(r)) return 'The address does not exist: check the adjuster\'s email.';
  if (/5\.2\.2|mailbox full|quota/i.test(r)) return 'The mailbox is full.';
  if (/5\.7\.1\b|spam|blocked|policy|rejected/i.test(r)) return 'Their mail server refused it by its policy.';
  return 'Their mail server refused it.';
}
