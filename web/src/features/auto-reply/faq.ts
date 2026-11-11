// AI auto-replies (release 36, migration 2110): the pure part. A question that came in by text, email, WhatsApp, Messenger
// or Instagram is answered only from the site's FAQ (the FAQ page's questions and answers with their {{tokens}} filled, and
// the owners' FAQ): the few FAQ entries closest to the question are given to the model (a small prompt keeps it inside the
// free Workers AI allowance), the model says which entry answers it and how sure it is, and anything it is not sure of, or
// that no entry answers, goes to staff. Nothing here calls the model or the database (server/auto-reply.ts does).

export type Channel = 'sms' | 'email' | 'chat' | 'whatsapp' | 'messenger' | 'instagram';
export interface FaqEntry { key: string; q: string; a: string }
export interface ModelAnswer { faq: string[]; answer: string; confident: boolean; confidence: number }

const STOP = new Set(('a an and are as at be by can do does for from have how i if in is it me my of on or our the there this to we what when where which who '
  + 'will with you your can i are there please hi hello thanks thank much get got any').split(' '));
/** The words of a text that carry its meaning (lower case, no stop words, a plural's s dropped). */
export function words(s: string): string[] {
  return (s.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').match(/[a-z0-9$]+/g) ?? [])
    .filter((w) => w.length > 1 && !STOP.has(w)).map((w) => (w.length > 3 && w.endsWith('s') ? w.slice(0, -1) : w));
}

/** The k FAQ entries that share the most meaningful words with the question (the question's own words count twice). */
export function closest(question: string, faq: FaqEntry[], k = 4): FaqEntry[] {
  const q = new Set(words(question));
  if (!q.size) return [];
  return faq.map((e) => {
    const inQ = words(e.q), inA = new Set(words(e.a));
    let s = 0;
    for (const w of new Set(inQ)) if (q.has(w)) s += 2;
    for (const w of inA) if (q.has(w)) s += 1;
    return { e, s };
  }).filter((x) => x.s >= 2).sort((a, b) => b.s - a.s).slice(0, k).map((x) => x.e);
}

export const ANSWER_SCHEMA = {
  type: 'object',
  properties: { faq: { type: 'array', items: { type: 'string' } }, answer: { type: 'string' }, confident: { type: 'boolean' }, confidence: { type: 'number' } },
  required: ['faq', 'answer', 'confident', 'confidence']
};

export function systemPrompt(brand: string): string {
  return [
    `You answer customer questions for ${brand}, a car rental company in Toronto, using ONLY the FAQ entries given.`,
    'Rules: answer only when one or more FAQ entries clearly answer the question; use their facts and numbers exactly, never add a fact, price, promise or policy that is not in them.',
    'If the question is about a booking, a payment, a complaint, an accident, damage, a specific car\'s availability or anything personal, or no entry answers it, set confident to false and answer to "".',
    'Write plainly and briefly, friendly, no greeting line, no sign-off, no long dashes.',
    'Reply in JSON only: {"faq": [keys of the entries used], "answer": "...", "confident": true or false, "confidence": 0 to 1}.'
  ].join(' ');
}

export function userPrompt(question: string, entries: FaqEntry[], channel: Channel): string {
  const len = channel === 'sms' ? 'at most 300 characters' : 'at most 120 words';
  return `<faq>\n${entries.map((e) => `[${e.key}] Q: ${e.q}\nA: ${e.a}`).join('\n\n')}\n</faq>\n<question>\n${question.slice(0, 800)}\n</question>\nAnswer in ${len}.`;
}

/** The model's answer checked: only FAQ keys that were given, a confidence between 0 and 1, the text tidied and cut to the
 *  channel's length. Anything malformed counts as "not sure". */
export function readAnswer(raw: unknown, given: FaqEntry[], channel: Channel): ModelAnswer {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const keys = new Set(given.map((e) => e.key));
  const faq = Array.isArray(r.faq) ? r.faq.map(String).filter((k) => keys.has(k)) : [];
  const confidence = typeof r.confidence === 'number' && Number.isFinite(r.confidence) ? Math.max(0, Math.min(1, r.confidence)) : 0;
  let answer = typeof r.answer === 'string' ? tidy(r.answer) : '';
  const max = channel === 'sms' ? 320 : 1200;
  if (answer.length > max) answer = `${answer.slice(0, max - 1).replace(/\s+\S*$/, '')}…`;
  // an answer that names no FAQ entry it used is not from the FAQ
  const confident = r.confident === true && faq.length > 0 && answer.length >= 8;
  return { faq, answer: confident ? answer : '', confident, confidence: confident ? confidence : 0 };
}

export function tidy(s: string): string {
  return s.replace(/\s*\u2014\s*/g, ', ').replace(/\u2013/g, '-').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').replace(/^(hi|hello|hey)[^a-z0-9]*\s*/i, '').trim();
}

/** A question worth answering: some words, not a one-word "ok", "thanks" or "stop" (opt-outs are the phone line's). */
export function isQuestion(text: string): boolean {
  const t = text.trim();
  if (/^(stop|start|unstop|unsubscribe|cancel|end|quit|help|yes|no|ok|okay|thanks|thank you|k|y|n)[.!]*$/i.test(t)) return false;
  return words(t).length >= 2;
}

/** An email that must never get an automatic answer: from a robot or a list, an automatic reply, a bounce, our own address. */
export function robotEmail(h: Record<string, string>, from: string, ownDomains: string[] = ['carmacars.ca']): boolean {
  const auto = (h['auto-submitted'] ?? '').toLowerCase();
  if (auto && auto !== 'no') return true;
  if (/^(bulk|list|junk|auto_reply)$/i.test((h.precedence ?? '').trim())) return true;
  if (h['list-id'] || h['list-unsubscribe'] || h['x-autoreply'] || h['x-autorespond'] || h['x-auto-response-suppress']) return true;
  const a = from.toLowerCase();
  if (/(^|[<\s])(no-?reply|do-?not-?reply|mailer-daemon|postmaster|bounce[s]?|notifications?)@/.test(a)) return true;
  return ownDomains.some((d) => new RegExp(`@([a-z0-9-]+\\.)*${d.replace(/\./g, '\\.')}>?$`).test(a.trim()));
}

/** The reply email as MIME (text only), answering the message it replies to (In-Reply-To, References). */
export function replyMime(o: { from: string; to: string; subject: string; text: string; inReplyTo: string | null; id: string; date: Date }): string {
  const enc = (s: string) => (/^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${btoa(String.fromCharCode(...new TextEncoder().encode(s)))}?=`);
  const subject = /^re:/i.test(o.subject.trim()) ? o.subject.trim() : `Re: ${o.subject.trim() || 'Your question'}`;
  const ref = o.inReplyTo ? `<${o.inReplyTo.replace(/[<>\s]/g, '')}>` : null;
  return [
    `From: ${o.from}`, `To: ${o.to}`, `Subject: ${enc(subject.slice(0, 200))}`, `Date: ${o.date.toUTCString()}`, `Message-ID: <${o.id}>`,
    ...(ref ? [`In-Reply-To: ${ref}`, `References: ${ref}`] : []),
    'Auto-Submitted: auto-replied', 'MIME-Version: 1.0', 'Content-Type: text/plain; charset=utf-8', 'Content-Transfer-Encoding: 8bit', '',
    o.text.replace(/\r?\n/g, '\r\n'), ''
  ].join('\r\n');
}
