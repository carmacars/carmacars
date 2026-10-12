import 'server-only';
import { block, getFacts, getSettings } from '@/lib/site';

// Renders the legal text (site_content_blocks legal.*, seeded from docs/source/website_terms_policies.md)
// to HTML: headings, paragraphs, lists and tables, the same rules as the prototype's renderer. Values
// that live in settings are filled here; a value not set yet is left out of the sentence, never shown
// as a blank.
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const mail = (a: string) => `<a class="link" href="mailto:${esc(a)}">${esc(a)}</a>`;

export async function legalValues(): Promise<Record<string, string>> {
  const [s, f, meta] = await Promise.all([getSettings(), getFacts(), block('legal.meta')]);
  const m = (meta?.data ?? {}) as { last_updated?: string; other_countries?: string | null };
  const officer = [f.privacy_officer_name ? esc(f.privacy_officer_name) : '', f.privacy_officer_email ? `${mail(f.privacy_officer_email)} (email)` : '', s.mailing_address ? `${esc(s.mailing_address)} (address)` : ''].filter(Boolean).join(', ');
  return {
    legalLastUpdated: esc(m.last_updated ?? ''),
    contactEmail: s.public_email ? mail(s.public_email) : '',
    bookingsEmail: f.email_aliases.bookings ? mail(f.email_aliases.bookings) : '',
    privacyOfficer: officer,
    otherCountries: m.other_countries ? ` and ${esc(m.other_countries)}` : '',
    mailingAddress: s.mailing_address ? `, ${esc(s.mailing_address)}` : ''
  };
}

export function renderLegal(src: string, v: Record<string, string>): string {
  const slug = (s: string) => s.toLowerCase().replace(/^\d+\.\s*/, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  const inline = (s: string) => esc(s)
    .replace(/\{\{(\w+)\}\}/g, (_, k: string) => { if (!(k in v)) throw new Error(`Unknown legal token ${k}`); return v[k]!; })
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/\[([^\]]+)\]\((https:[^)]+)\)/g, '<a class="link" href="$2" rel="noopener">$1</a>')
    .replace(/priv\.gc\.ca/g, '<a class="link" href="https://www.priv.gc.ca/" rel="noopener">priv.gc.ca</a>');
  const lines = src.split('\n'); let out = ''; let i = 0;
  while (i < lines.length) {
    const l = lines[i]!;
    if (!l.trim()) { i++; continue; }
    if (/^### /.test(l)) { const t = l.slice(4); out += `<h2 class="d4" id="${slug(t)}">${inline(t)}</h2>`; i++; continue; }
    if (/^\|/.test(l)) {
      const rows: string[][] = [];
      while (i < lines.length && /^\|/.test(lines[i]!)) { rows.push(lines[i]!.split('|').slice(1, -1).map((c) => c.trim())); i++; }
      const [h, , ...body] = rows;
      out += `<div class="table-scroll" tabindex="0" role="region" aria-label="Table"><table class="data"><thead><tr>${h!.map((c) => `<th scope="col">${inline(c)}</th>`).join('')}</tr></thead><tbody>${body.map((r) => `<tr>${r.map((c, j) => (j === 0 ? `<th scope="row">${inline(c)}</th>` : `<td>${inline(c)}</td>`)).join('')}</tr>`).join('')}</tbody></table></div>`;
      continue;
    }
    if (/^- /.test(l)) { out += '<ul>'; while (i < lines.length && /^- /.test(lines[i]!)) { out += `<li>${inline(lines[i]!.slice(2))}</li>`; i++; } out += '</ul>'; continue; }
    const m = l.match(/^\*\*(\d+)\. (.+?)\.\*\*\s*(.*)$/);
    if (m) { out += `<h2 class="d4" id="s${m[1]}">${m[1]}. ${inline(m[2]!)}</h2>${m[3] ? `<p>${inline(m[3])}</p>` : ''}`; i++; continue; }
    out += `<p>${inline(l)}</p>`; i++;
  }
  return out;
}

export async function legalHtml(key: 'legal.terms' | 'legal.privacy' | 'legal.cancellation'): Promise<string> {
  const b = await block(key);
  if (!b?.body) return '';
  return renderLegal(b.body, await legalValues());
}
