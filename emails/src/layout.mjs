// Shared layout: turns an email definition into an HTML template and a plain-text template.
// Table-based, inline-styled, single column, 600px. Merge tags are left in place for the engine.
import { BRAND, C, FONT, FONT_WORDMARK } from './brand.mjs';

// The wordmark: the exact string CarmaCars, "Carma" in the surface text colour and "Cars" in red, bold italic condensed.
const wordmark = (size, carma, cls = '') =>
  `<span${cls ? ` class="${cls}"` : ''} style="font-family:${FONT_WORDMARK};font-size:${size}px;line-height:${size + 4}px;font-weight:700;font-style:italic;letter-spacing:-0.01em;color:${carma};">Carma<span style="color:${C.red};">Cars</span></span>`;
import { url, PATHS } from './links.mjs';
import { escapeHtml } from './engine.mjs';

const PAD = 36;

// ---------- inline copy ----------
function href(target) {
  if (target.startsWith('@')) return url(target.slice(1));
  return target;
}
// Escape literal copy but leave merge tags alone.
function esc(s) {
  return String(s).split(/(\{\{[^}]*\}\})/).map((part, i) => (i % 2 ? part : escapeHtml(part))).join('');
}
function inlineHtml(text, linkColor = C.ink) {
  let out = esc(text).replace(/\{\{(support_phone|roadside_phone)\}\}/g, '<span style="white-space:nowrap;">{{$1}}</span>');
  out = out.replace(/\*\*(.+?)\*\*/g, '<strong style="font-weight:700;">$1</strong>');
  out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, target) =>
    `<a href="${href(target)}" style="color:${linkColor};text-decoration:underline;" class="tx">${label}</a>`);
  return out;
}
function inlineText(text) {
  return String(text)
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, target) => `${label} (${href(target)})`);
}

const section = (inner, bottom = 24) =>
  `<tr><td class="px" style="padding:0 ${PAD}px ${bottom}px ${PAD}px;">${inner}</td></tr>\n`;
const wrapIf = (name, inner, otherwise = '') =>
  name ? `{{#if ${name}}}${inner}${otherwise ? `{{else}}${otherwise}` : ''}{{/if}}` : inner;
const label = (text) =>
  `<div class="tx-soft" style="font-family:${FONT};font-size:11px;line-height:16px;letter-spacing:1.4px;text-transform:uppercase;color:${C.soft};font-weight:700;">${esc(text)}</div>`;

// ---------- HTML blocks ----------
const H = {
  p: (b) => section(`<p class="tx" style="margin:0;font-family:${FONT};font-size:16px;line-height:26px;color:${C.ink};">${inlineHtml(b.text)}</p>`, 20),
  small: (b) => section(`<p class="tx-mid" style="margin:0;font-family:${FONT};font-size:13px;line-height:21px;color:${C.mid};">${inlineHtml(b.text, C.mid)}</p>`, 20),
  h: (b) => section(`<h2 class="tx" style="margin:8px 0 0 0;font-family:${FONT};font-size:18px;line-height:24px;font-weight:700;letter-spacing:-0.2px;color:${C.ink};">${inlineHtml(b.text)}</h2>`, 12),
  rule: () => section(`<div class="rule" style="border-top:1px solid ${C.rule};font-size:0;line-height:0;height:0;">&nbsp;</div>`, 24),

  vehicle: (b) => section(
    `{{#if vehicle_image_url}}<img src="{{vehicle_image_url}}" width="528" alt="{{vehicle_name}}" style="display:block;width:100%;max-width:528px;height:auto;border:0;outline:none;border-radius:4px;background-color:${C.slot};color:#FFFFFF;font-family:${FONT};font-size:16px;">{{else}}` +
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr><td align="center" valign="middle" height="190" bgcolor="${C.slot}" style="height:190px;background-color:${C.slot};border-radius:4px;padding:0 20px;">` +
    `<div style="font-family:${FONT};font-size:11px;line-height:16px;letter-spacing:1.6px;text-transform:uppercase;color:${C.labelOnBlack};font-weight:700;">Your vehicle</div>` +
    `<div style="font-family:${FONT};font-size:22px;line-height:30px;font-weight:700;letter-spacing:-0.3px;color:#FFFFFF;padding-top:4px;">{{vehicle_name}}</div>` +
    `</td></tr></table>{{/if}}` +
    (b.caption ? `<div class="tx-mid" style="font-family:${FONT};font-size:13px;line-height:20px;color:${C.mid};padding-top:10px;">${inlineHtml(b.caption, C.mid)}</div>` : ''), 28),

  keyfacts: (b) => {
    const w = Math.floor(100 / b.items.length);
    const cells = b.items.map((it, i) =>
      `<td class="kf" width="${w}%" valign="top" style="width:${w}%;padding:0 ${i < b.items.length - 1 ? 16 : 0}px 0 0;">` +
      `<div class="rule-strong" style="border-top:2px solid ${C.black};padding-top:12px;">${label(it.label)}` +
      `<div class="tx kfv" style="font-family:${FONT};font-size:19px;line-height:26px;font-weight:700;letter-spacing:-0.3px;color:${C.ink};padding-top:4px;">${inlineHtml(it.value)}</div>` +
      (it.sub ? `<div class="tx-mid" style="font-family:${FONT};font-size:14px;line-height:21px;color:${C.mid};padding-top:2px;">${inlineHtml(it.sub, C.mid)}</div>` : '') +
      `</div></td>`).join('');
    return section(`<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr>${cells}</tr></table>`, 28);
  },

  figure: (b) => section(
    `<div class="rule-strong" style="border-top:2px solid ${C.black};padding-top:12px;">${label(b.label)}` +
    `<div style="font-family:${FONT};font-size:38px;line-height:46px;font-weight:700;letter-spacing:-1px;color:${C.red};padding-top:2px;">${inlineHtml(b.value)}</div>` +
    (b.sub ? `<div class="tx-mid" style="font-family:${FONT};font-size:14px;line-height:22px;color:${C.mid};padding-top:4px;">${inlineHtml(b.sub, C.mid)}</div>` : '') +
    `</div>`, 28),

  facts: (b) => {
    const trs = b.rows.map((r) => wrapIf(r.when,
      `<tr><td class="tx-mid rule fl" width="36%" valign="top" style="width:36%;padding:11px 12px 11px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:14px;line-height:22px;color:${C.mid};">${esc(r.label)}</td>` +
      `<td class="tx rule" valign="top" style="padding:11px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:15px;line-height:22px;color:${C.ink};font-weight:600;">${inlineHtml(r.value)}</td></tr>`)).join('\n');
    return section(`<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="rule" style="border-top:1px solid ${C.rule};">\n${trs}\n</table>`, 28);
  },

  price: (b) => {
    const line = (l, a, bold) =>
      `<tr><td class="${bold ? 'tx' : 'tx-mid'} rule" valign="top" style="padding:10px 12px 10px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:15px;line-height:22px;color:${bold ? C.ink : C.mid};">${l}</td>` +
      `<td class="tx rule" align="right" valign="top" style="padding:10px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:15px;line-height:22px;color:${C.ink};white-space:nowrap;">${a}</td></tr>`;
    let trs = '';
    if (b.each) trs += `{{#each ${b.each}}}${line('{{label}}', '{{amount}}')}{{/each}}\n`;
    trs += b.rows.map((r) => wrapIf(r.when, line(inlineHtml(r.label, C.mid), inlineHtml(r.value)))).join('\n');
    if (b.total) {
      trs += `\n<tr><td class="tx rule-strong" valign="middle" style="padding:14px 12px 14px 0;border-bottom:2px solid ${C.black};font-family:${FONT};font-size:16px;line-height:22px;font-weight:700;color:${C.ink};">${inlineHtml(b.total[0])}</td>` +
        `<td class="rule-strong" align="right" valign="middle" style="padding:14px 0;border-bottom:2px solid ${C.black};font-family:${FONT};font-size:22px;line-height:28px;font-weight:700;letter-spacing:-0.4px;color:${C.red};white-space:nowrap;">${inlineHtml(b.total[1])}</td></tr>`;
    }
    trs += b.after.map((r) => wrapIf(r.when, line(inlineHtml(r.label, C.mid), inlineHtml(r.value)))).join('\n');
    return section(`<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="rule-strong" style="border-top:2px solid ${C.black};">\n${trs}\n</table>`, 28);
  },

  compare: (b) => {
    const th = (t, w) => `<td class="tx-soft rule-strong" ${w ? `width="${w}" ` : ''}valign="bottom" style="padding:0 10px 8px 0;border-bottom:2px solid ${C.black};font-family:${FONT};font-size:11px;line-height:16px;letter-spacing:1.2px;text-transform:uppercase;font-weight:700;color:${C.soft};">${esc(t)}</td>`;
    return section(
      `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr>${th('Changed', '24%')}${th(b.beforeHead, '38%')}${th(b.afterHead)}</tr>\n` +
      `{{#each ${b.each}}}<tr><td class="tx-mid rule" valign="top" style="padding:12px 10px 12px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:14px;line-height:21px;color:${C.mid};">{{label}}</td>` +
      `<td class="tx-soft rule" valign="top" style="padding:12px 10px 12px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:14px;line-height:21px;color:${C.soft};text-decoration:line-through;">{{before}}</td>` +
      `<td class="tx rule" valign="top" style="padding:12px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:15px;line-height:21px;font-weight:700;color:${C.ink};">{{after}}</td></tr>{{/each}}\n</table>`, 28);
  },

  table: (b) => {
    const head = `<tr>${b.cols.map((c, i) => `<td class="tx-soft rule-strong" align="${c.align || 'left'}" valign="bottom" style="padding:0 ${i < b.cols.length - 1 ? 10 : 0}px 8px 0;border-bottom:2px solid ${C.black};font-family:${FONT};font-size:11px;line-height:16px;letter-spacing:1.2px;text-transform:uppercase;font-weight:700;color:${C.soft};">${esc(c.head)}</td>`).join('')}</tr>`;
    const body = `<tr>${b.cols.map((c, i) => `<td class="${c.strong ? 'tx' : 'tx-mid'} rule" align="${c.align || 'left'}" valign="top" style="padding:11px ${i < b.cols.length - 1 ? 10 : 0}px 11px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:14px;line-height:21px;color:${c.strong ? C.ink : C.mid};${c.strong ? 'font-weight:600;' : ''}${c.align === 'right' ? 'white-space:nowrap;' : ''}">${inlineHtml(c.value, c.strong ? C.ink : C.mid)}</td>`).join('')}</tr>`;
    const foot = (b.foot || []).map((f) =>
      `<tr><td class="tx rule" colspan="${b.cols.length - 1}" style="padding:11px 10px 11px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:15px;line-height:22px;font-weight:700;color:${C.ink};">${inlineHtml(f[0])}</td>` +
      `<td class="tx rule" align="right" style="padding:11px 0;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:15px;line-height:22px;font-weight:700;color:${C.ink};white-space:nowrap;">${inlineHtml(f[1])}</td></tr>`).join('');
    return section(`<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0">${head}\n{{#each ${b.each}}}${body}{{/each}}\n${foot}</table>`, 28);
  },

  rows: (b) => section(
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="rule" style="border-top:1px solid ${C.rule};">\n{{#each ${b.each}}}` +
    `<tr><td class="rule" valign="top" style="padding:12px 0;border-bottom:1px solid ${C.rule};">` +
    `<a href="${href(b.href)}" class="tx" style="font-family:${FONT};font-size:15px;line-height:22px;font-weight:700;color:${C.ink};text-decoration:none;">${esc(b.title)}</a>` +
    (b.meta ? `<div class="tx-mid" style="font-family:${FONT};font-size:14px;line-height:21px;color:${C.mid};padding-top:2px;">${esc(b.meta)}</div>` : '') +
    `</td><td class="rule" width="24" align="right" valign="middle" style="width:24px;border-bottom:1px solid ${C.rule};font-family:${FONT};font-size:18px;line-height:22px;color:${C.red};"><a href="${href(b.href)}" style="color:${C.red};text-decoration:none;">&rsaquo;</a></td></tr>{{/each}}\n</table>`, 28),

  button: (b) => section(
    `<table role="presentation" cellspacing="0" cellpadding="0" border="0" class="btn"><tr><td align="center" bgcolor="${C.red}" style="background-color:${C.red};border-radius:6px;">` +
    `<a href="${href(b.href)}" target="_blank" style="display:inline-block;padding:17px 34px;font-family:${FONT};font-size:16px;line-height:20px;font-weight:700;color:#FFFFFF;text-decoration:none;border-radius:6px;border:1px solid ${C.redDark};mso-padding-alt:0;">${esc(b.label)}</a>` +
    `</td></tr></table>`, 24),

  link: (b) => section(
    `<a href="${href(b.href)}" class="tx" style="font-family:${FONT};font-size:15px;line-height:22px;font-weight:700;color:${C.ink};text-decoration:underline;">${esc(b.label)}</a>`, 24),

  notice: (b) => section(
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr>` +
    `<td width="4" bgcolor="${b.tone === 'alert' ? C.red : C.black}" class="${b.tone === 'alert' ? '' : 'bar'}" style="width:4px;background-color:${b.tone === 'alert' ? C.red : C.black};font-size:0;line-height:0;">&nbsp;</td>` +
    `<td class="wash" bgcolor="${C.wash}" style="background-color:${C.wash};padding:16px 18px;">` +
    (b.title ? `<div class="tx" style="font-family:${FONT};font-size:15px;line-height:22px;font-weight:700;color:${C.ink};padding-bottom:${b.text ? 4 : 0}px;">${inlineHtml(b.title)}</div>` : '') +
    (b.text ? `<div class="tx" style="font-family:${FONT};font-size:15px;line-height:23px;color:${C.ink};">${inlineHtml(b.text)}</div>` : '') +
    `</td></tr></table>`, 24),

  list: (b) => section(
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0">` +
    b.items.map((it) => `<tr><td width="18" valign="top" style="width:18px;font-family:${FONT};font-size:16px;line-height:25px;color:${C.red};font-weight:700;">&bull;</td><td class="tx" valign="top" style="font-family:${FONT};font-size:16px;line-height:25px;color:${C.ink};padding-bottom:6px;">${inlineHtml(it)}</td></tr>`).join('') +
    `</table>`, 18),

  steps: (b) => section(
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0">` +
    b.items.map(([t, d], i) => `<tr><td width="38" valign="top" style="width:38px;padding-bottom:16px;"><div class="num" style="width:26px;height:26px;border-radius:13px;background-color:${C.black};color:#FFFFFF;font-family:${FONT};font-size:13px;line-height:26px;font-weight:700;text-align:center;">${i + 1}</div></td>` +
      `<td valign="top" style="padding-bottom:16px;"><div class="tx" style="font-family:${FONT};font-size:16px;line-height:24px;font-weight:700;color:${C.ink};">${inlineHtml(t)}</div>` +
      (d ? `<div class="tx-mid" style="font-family:${FONT};font-size:15px;line-height:23px;color:${C.mid};padding-top:2px;">${inlineHtml(d, C.mid)}</div>` : '') + `</td></tr>`).join('') +
    `</table>`, 12),

  when: (b) => `{{#if ${b.name}}}\n${blocksHtml(b.then)}${b.otherwise.length ? `{{else}}\n${blocksHtml(b.otherwise)}` : ''}{{/if}}\n`,
  each: (b) => `{{#each ${b.name}}}\n${blocksHtml(b.blocks)}{{/each}}\n`,
};

function blocksHtml(blocks) {
  return blocks.map((b) => {
    if (!H[b.type]) throw new Error('Unknown block: ' + b.type);
    return H[b.type](b);
  }).join('');
}

// ---------- plain-text blocks ----------
const pad = (s, n) => (s.length >= n ? s + ' ' : s + ' '.repeat(n - s.length));
const T = {
  p: (b) => inlineText(b.text),
  small: (b) => inlineText(b.text),
  h: (b) => inlineText(b.text) + '\n' + '-'.repeat(24),
  rule: () => '----------------------------------------',
  vehicle: (b) => '{{vehicle_name}}' + (b.caption ? '\n' + inlineText(b.caption) : ''),
  keyfacts: (b) => b.items.map((it) => `${it.label}: ${inlineText(it.value)}${it.sub ? ', ' + inlineText(it.sub) : ''}`).join('\n'),
  figure: (b) => `${b.label}: ${inlineText(b.value)}${b.sub ? '\n' + inlineText(b.sub) : ''}`,
  facts: (b) => b.rows.map((r) => (r.when ? `{{#if ${r.when}}}\n${r.label}: ${inlineText(r.value)}\n{{/if}}` : `${r.label}: ${inlineText(r.value)}`)).join('\n'),
  price: (b) => {
    const out = [];
    if (b.each) out.push(`{{#each ${b.each}}}\n  {{label}}: {{amount}}\n{{/each}}`);
    const line = (r) => (r.when ? `{{#if ${r.when}}}\n  ${inlineText(r.label)}: ${inlineText(r.value)}\n{{/if}}` : `  ${inlineText(r.label)}: ${inlineText(r.value)}`);
    b.rows.forEach((r) => out.push(line(r)));
    if (b.total) out.push(`  ${inlineText(b.total[0])}: ${inlineText(b.total[1])}`);
    b.after.forEach((r) => out.push(line(r)));
    return out.join('\n');
  },
  compare: (b) => `{{#each ${b.each}}}\n  {{label}}: was {{before}}, now {{after}}\n{{/each}}`,
  table: (b) => `{{#each ${b.each}}}\n  ${b.cols.map((c) => (c.head ? c.head + ': ' : '') + inlineText(c.value)).join(' | ')}\n{{/each}}` +
    (b.foot || []).map((f) => `\n  ${inlineText(f[0])}: ${inlineText(f[1])}`).join(''),
  rows: (b) => `{{#each ${b.each}}}\n- ${b.title}${b.meta ? '\n  ' + b.meta : ''}\n  ${href(b.href)}\n{{/each}}`,
  button: (b) => `${b.label}:\n${href(b.href)}`,
  link: (b) => `${b.label}: ${href(b.href)}`,
  notice: (b) => [b.title ? (b.tone === 'alert' ? 'IMPORTANT: ' : '') + inlineText(b.title) : '', b.text ? inlineText(b.text) : ''].filter(Boolean).join('\n'),
  list: (b) => b.items.map((it) => '- ' + inlineText(it)).join('\n'),
  steps: (b) => b.items.map(([t, d], i) => `${i + 1}. ${inlineText(t)}${d ? '\n   ' + inlineText(d) : ''}`).join('\n'),
  when: (b) => `{{#if ${b.name}}}\n${blocksText(b.then)}\n${b.otherwise.length ? `{{else}}\n${blocksText(b.otherwise)}\n` : ''}{{/if}}`,
  each: (b) => `{{#each ${b.name}}}\n${blocksText(b.blocks)}\n\n{{/each}}`,
};
function blocksText(blocks) {
  return blocks.map((b) => T[b.type](b)).join('\n\n');
}

// ---------- footer copy ----------
const STAFF = (a) => a.startsWith('staff_');
function helpLine(email) {
  if (email.help) return email.help;
  if (STAFF(email.audience)) return 'If this notice looks wrong, tell an admin.';
  if (email.audience === 'investor') return '**Help:** reply to this email or call {{support_phone}}. We reply {{reply_time}}.';
  return '**Help:** reply to this email or call {{support_phone}}. We reply {{reply_time}}, day or night.';
}
// Public contact and social lines for renters, owners and investors (not on internal staff notices).
const CONTACT_LINE = 'Questions: {{contact_email}} or {{support_phone}}. {{opening_hours}}. We reply {{reply_time}}.';
function reason(email) {
  if (email.footer) return email.footer;
  if (email.category === 'marketing') return 'You are receiving this because you agreed to get CarmaCars offers by email.';
  if (STAFF(email.audience)) return 'Internal CarmaCars notice. It may contain customer information. Do not forward it.';
  if (email.audience === 'investor') return 'This is a servicing notice for an existing investor. It is not an offer or a solicitation.';
  if (email.audience === 'owner') return 'You are receiving this because you have an owner account with CarmaCars. Notices about your vehicles, fees and payouts are always sent.';
  if (email.audience === 'insurer') return 'You are receiving this because you are the billing contact for a claim with a replacement rental from CarmaCars.';
  return 'You are receiving this because you have an account or a booking with CarmaCars. Messages about your booking, payments or safety are always sent.';
}

// ---------- document ----------
export function htmlTemplate(email) {
  const heroB = email.body.find((b) => b.type === 'hero');
  const rest = email.body.filter((b) => b.type !== 'hero');
  const marketing = email.category === 'marketing';
  const staff = STAFF(email.audience);
  const fl = (name, text) => `<a href="${url(name)}" class="tx-mid" style="color:${C.mid};text-decoration:underline;">${text}</a>`;

  return `<!DOCTYPE html>
<html lang="en-CA" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="format-detection" content="telephone=no, date=no, address=no, email=no">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>${esc(email.subject)}</title>
<!--[if mso]><noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript><style>table,td,div,p,a,h1,h2{font-family:Arial,sans-serif !important;}</style><![endif]-->
<style>
:root{color-scheme:light dark;supported-color-schemes:light dark;}
body{margin:0;padding:0;width:100% !important;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;}
table{border-collapse:collapse;mso-table-lspace:0;mso-table-rspace:0;}
img{-ms-interpolation-mode:bicubic;}
a{text-decoration:underline;}
@media only screen and (max-width:480px){
  .px{padding-left:22px !important;padding-right:22px !important;}
  .hero-title{font-size:27px !important;line-height:33px !important;}
  .btn{width:100% !important;}
  .btn a{display:block !important;padding-left:12px !important;padding-right:12px !important;}
  .ref{display:none !important;}
  .fl{width:40% !important;}
  .kfv{font-size:17px !important;line-height:23px !important;}
}
@media (prefers-color-scheme:dark){
  .page{background-color:#000000 !important;}
  .card{background-color:#111111 !important;}
  .tx{color:#F3F3F3 !important;}
  .tx-mid{color:#A3A3A3 !important;}
  .tx-soft{color:#909090 !important;}
  .rule{border-color:#2B2B2B !important;}
  .rule-strong{border-color:#F3F3F3 !important;}
  .wash{background-color:#1A1A1A !important;}
  .bar{background-color:#F3F3F3 !important;}
  .num{background-color:#F3F3F3 !important;color:#000000 !important;}
  .foot{background-color:#000000 !important;}
}
[data-ogsc] .tx{color:#F3F3F3 !important;}
[data-ogsc] .tx-mid{color:#A3A3A3 !important;}
[data-ogsc] .tx-soft{color:#909090 !important;}
</style>
</head>
<body class="page" style="margin:0;padding:0;background-color:${C.page};">
<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">${esc(email.preheader)}${'&#847;&zwnj;&nbsp;'.repeat(40)}</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="page" bgcolor="${C.page}" style="background-color:${C.page};">
<tr><td align="center" style="padding:0;">
<!--[if mso]><table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" align="center"><tr><td><![endif]-->
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="card" bgcolor="${C.white}" style="width:100%;max-width:600px;background-color:${C.white};">
<tr><td bgcolor="${C.red}" height="4" style="height:4px;background-color:${C.red};font-size:0;line-height:0;">&nbsp;</td></tr>
<tr><td class="px" bgcolor="${C.black}" style="background-color:${C.black};padding:26px ${PAD}px 0 ${PAD}px;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr>
<td align="left" valign="middle"><a href="${url('home')}" style="text-decoration:none;color:#FFFFFF;">${wordmark(30, '#FFFFFF')}</a></td>
<td class="ref" align="right" valign="middle" style="font-family:${FONT};font-size:11px;line-height:16px;letter-spacing:1.4px;text-transform:uppercase;font-weight:700;color:${C.labelOnBlack};">${esc(email.ref || '')}</td>
</tr></table>
</td></tr>
<tr><td class="px" bgcolor="${C.black}" style="background-color:${C.black};padding:34px ${PAD}px 38px ${PAD}px;">
<div style="width:36px;height:3px;background-color:${C.red};font-size:0;line-height:0;">&nbsp;</div>
<div style="font-family:${FONT};font-size:11px;line-height:16px;letter-spacing:1.6px;text-transform:uppercase;font-weight:700;color:${C.onBlack};padding-top:14px;">${esc(heroB.eyebrow)}</div>
<h1 class="hero-title" style="margin:0;padding-top:8px;font-family:${FONT};font-size:32px;line-height:38px;font-weight:700;letter-spacing:-0.9px;color:#FFFFFF;">${inlineHtml(heroB.title, '#FFFFFF')}</h1>
${heroB.lead ? `<div style="font-family:${FONT};font-size:16px;line-height:25px;color:${C.onBlack};padding-top:12px;">${inlineHtml(heroB.lead, '#FFFFFF').replace(/class="tx"/g, '')}</div>` : ''}
</td></tr>
<tr><td height="34" style="height:34px;font-size:0;line-height:0;">&nbsp;</td></tr>
${blocksHtml(rest)}<tr><td class="px" style="padding:4px ${PAD}px 34px ${PAD}px;"><div class="rule" style="border-top:1px solid ${C.rule};padding-top:20px;font-family:${FONT};font-size:15px;line-height:23px;color:${C.ink};"><span class="tx">${inlineHtml(helpLine(email))}</span></div></td></tr>
<tr><td class="px foot" bgcolor="${C.wash}" style="background-color:${C.wash};padding:26px ${PAD}px 30px ${PAD}px;">
<div>${wordmark(21, C.ink, 'tx')}</div>
<div class="tx-mid" style="font-family:${FONT};font-size:12px;line-height:19px;color:${C.mid};padding-top:8px;">${esc(reason(email))}</div>
${marketing ? `<div class="tx-mid" style="font-family:${FONT};font-size:12px;line-height:19px;color:${C.mid};padding-top:8px;"><a href="{{unsubscribe_url}}" class="tx" style="color:${C.ink};text-decoration:underline;font-weight:700;">Unsubscribe</a> at any time. We act on it within 10 business days.</div>` : ''}
${staff ? '' : `<div class="tx-mid" style="font-family:${FONT};font-size:12px;line-height:19px;color:${C.mid};padding-top:8px;">${inlineHtml(CONTACT_LINE).replace(/class="tx"/g, '')}</div>`}
<div class="tx-mid" style="font-family:${FONT};font-size:12px;line-height:19px;color:${C.mid};padding-top:8px;">CarmaCars<br>{{company_address}}</div>
<div class="tx-mid" style="font-family:${FONT};font-size:12px;line-height:19px;color:${C.mid};padding-top:8px;">${fl('home', 'carmacars.ca')}${staff ? '' : ` &nbsp;&middot;&nbsp; ${fl('terms', 'Terms')} &nbsp;&middot;&nbsp; ${fl('privacy', 'Privacy')} &nbsp;&middot;&nbsp; <a href="{{instagram_url}}" class="tx-mid" style="color:${C.mid};text-decoration:underline;">Instagram</a> &nbsp;&middot;&nbsp; <a href="{{tiktok_url}}" class="tx-mid" style="color:${C.mid};text-decoration:underline;">TikTok</a>`}</div>
</td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr>
</table>
</body>
</html>
`;
}

export function textTemplate(email) {
  const heroB = email.body.find((b) => b.type === 'hero');
  const rest = email.body.filter((b) => b.type !== 'hero');
  const parts = [
    'CarmaCars' + (email.ref ? '  |  ' + email.ref : ''),
    '========================================',
    '[' + heroB.eyebrow + ']\n' + inlineText(heroB.title) + (heroB.lead ? '\n\n' + inlineText(heroB.lead) : ''),
    blocksText(rest),
    '----------------------------------------',
    inlineText(helpLine(email)),
    reason(email) + (email.category === 'marketing' ? '\nUnsubscribe at any time: {{unsubscribe_url}}\nWe act on it within 10 business days.' : ''),
    STAFF(email.audience) ? '' : CONTACT_LINE,
    `CarmaCars\n{{company_address}}\n${url('home')}` + (STAFF(email.audience) ? '' : '\nInstagram: {{instagram_url}}\nTikTok: {{tiktok_url}}'),
  ];
  return parts.join('\n\n').replace(/\n{3,}/g, '\n\n') + '\n';
}

export { PATHS };
