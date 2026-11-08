// r35 (migration 0900): several emails to the same person for the same booking, queued within a short window, go as one.
// Pure: the send-outbox Edge Function imports this file (copied next to it at deploy time as combine.ts) and the unit
// tests read it. Each part is an email already rendered from its own template (emails/src/layout.mjs): its content, from
// the hero band to the last block before the help line, becomes a section of the combined email with its own buttons;
// the header, the help line and the footer are the first email's.

export interface RenderedPart { subject: string; html: string; text: string }

const HELP_ROW = '<tr><td class="px" style="padding:4px';
const TEXT_RULE = '========================================';
const TEXT_FOOT = '----------------------------------------';

/** The content rows of a rendered email: [start, end) in its HTML, or null when the layout is not recognised. */
export function contentRange(html: string): [number, number] | null {
  const hero = html.search(/<tr><td class="px" bgcolor="[^"]*" style="[^"]*padding:34px /);
  const end = html.indexOf(HELP_ROW);
  if (hero < 0 || end < 0 || end <= hero) return null;
  return [hero, end];
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** The row that opens each section after the first: a thin rule and the email's own subject. */
function sectionRow(subject: string, n: number, of: number): string {
  return `<tr><td class="px" style="padding:8px 40px 0 40px;"><div class="rule" style="border-top:1px solid #E4E4E4;padding-top:22px;font-family:Arial,Helvetica,sans-serif;font-size:11px;line-height:16px;letter-spacing:1.4px;text-transform:uppercase;font-weight:700;color:#6B6B6B;">${n} of ${of}</div><div style="font-family:Arial,Helvetica,sans-serif;font-size:18px;line-height:26px;font-weight:700;color:#111111;padding-top:4px;">${esc(subject)}</div></td></tr>\n<tr><td height="18" style="height:18px;font-size:0;line-height:0;">&nbsp;</td></tr>\n`;
}

/** The body of a plain-text email between its header and its help line. */
export function textContent(text: string): string {
  const a = text.indexOf(TEXT_RULE);
  const b = text.lastIndexOf(TEXT_FOOT);
  const from = a >= 0 ? a + TEXT_RULE.length : 0;
  return text.slice(from, b > from ? b : text.length).trim();
}

/** One email from several: the subject given, each part a section in order. One part comes back as it is. */
export function combineEmails(subject: string, parts: RenderedPart[]): { subject: string; html: string; text: string } {
  if (parts.length === 0) throw new Error('nothing to combine');
  if (parts.length === 1) return { subject: parts[0]!.subject, html: parts[0]!.html, text: parts[0]!.text };
  const first = parts[0]!;
  const r0 = contentRange(first.html);
  let html: string;
  if (r0) {
    const sections = parts.map((p, i) => {
      const r = contentRange(p.html);
      const body = r ? p.html.slice(r[0], r[1]) : `<tr><td class="px" style="padding:0 40px 20px 40px;">${esc(textContent(p.text)).replace(/\n/g, '<br>')}</td></tr>\n`;
      // the first section keeps its hero band; each later one opens with its number and subject
      return (i === 0 ? '' : sectionRow(p.subject, i + 1, parts.length)) + body;
    });
    html = first.html.slice(0, r0[0]) + sections.join('') + first.html.slice(r0[1]);
  } else {
    html = parts.map((p) => p.html).join('\n<hr>\n');
  }
  // the inbox preview line names what is inside
  html = html.replace(/(<div style="display:none;[^"]*">)[^<]*/, (_m, open: string) => open + esc(subject));
  const a = first.text.indexOf(TEXT_RULE);
  const b = first.text.lastIndexOf(TEXT_FOOT);
  const head = a >= 0 ? first.text.slice(0, a) : '';
  const foot = b >= 0 ? first.text.slice(b) : '';
  const text = head + TEXT_RULE + '\n\n' + subject + '\n\n' +
    parts.map((p, i) => `${i + 1} of ${parts.length}: ${p.subject}\n\n${textContent(p.text)}`).join('\n\n' + TEXT_RULE + '\n\n') + '\n\n' + foot;
  return { subject, html, text: text.replace(/\n{3,}/g, '\n\n') };
}
