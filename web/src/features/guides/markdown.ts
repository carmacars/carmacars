// The guides' Markdown (migration 0044, docs/guides/src/export.py): a small renderer with no raw HTML. Everything the
// author types is escaped; only the constructs below become markup. The same module renders the published guide (once,
// on the server when an Admin publishes) and the live preview in Admin > Settings > Guides (in the browser), so the two
// always match. Linear in the length of the text: a whole guide renders in a few milliseconds.
//
//   ## Task title                 a task (a section of its own, linked from the contents and found by search)
//   ### Small heading
//   1. step                       numbered steps; a list may start at any number
//   - item                        bullets
//   **Button label**  `carmacars.ca/address`  *italic*  [text](https://... or /path)
//   ![caption](/guides/img/x.jpg "phone; size: 390 645; pins: 1 45.2 30.1; boxes: 10 20 30 5; address: carmacars.ca/owner")
//                                 a screenshot; right after a list of steps it sits beside (phone) or below (desktop) them
//   > Tip: text                   a box (Tip, Good to know, Note: grey; Watch out, Important: red)
//   | a | b |  / | --- | --- |    a table with a header row
//   :::flow / Title | what happens / :::               numbered stages in a row
//   :::phones / 1. caption ![](src "phone") / :::     phone screens side by side, each with a numbered caption

export interface GuideImage { src: string; alt: string; phone: boolean; width?: number; height?: number; address?: string; pins: Array<{ n: string; x: number; y: number }>; boxes: Array<{ x: number; y: number; w: number; h: number }> }
export interface RenderResult { html: string; tasks: Array<{ id: string; title: string }>; images: string[]; warnings: string[] }

const ESC: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ESC[c]!);

export function slugify(s: string): string {
  return s.toLowerCase().normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'section';
}

const SAFE_URL = /^(https:\/\/[^\s"'<>]+|\/(?!\/)[^\s"'<>]*|#[a-z0-9-]+)$/i;

/** Inline text: escaped first, then code, bold, italic and links. */
export function inline(src: string): string {
  const codes: string[] = [];
  let s = src.replace(/`([^`\n]+)`/g, (_, c: string) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
  const links: string[] = [];
  s = s.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, label: string, url: string) => {
    if (!SAFE_URL.test(url)) return m;
    links.push(`<a class="gd-a" href="${esc(url)}"${url.startsWith('https://') ? ' rel="noopener" target="_blank"' : ''}>${inlineNoLinks(label)}</a>`);
    return `\u0001${links.length - 1}\u0001`;
  });
  s = inlineNoLinks(s);
  s = s.replace(/\u0001(\d+)\u0001/g, (_, i: string) => links[Number(i)]!);
  return s.replace(/\u0000(\d+)\u0000/g, (_, i: string) => `<span class="gd-url">${esc(codes[Number(i)]!)}</span>`);
}
function inlineNoLinks(s: string): string {
  return esc(s)
    .replace(/\*\*([^*\n]+?)\*\*/g, '<b class="gd-ui">$1</b>')
    .replace(/(^|[^*\w])\*([^*\n]+?)\*(?=[^*\w]|$)/g, '$1<em>$2</em>');
}

/** The image line: ![alt](src "phone; size: w h; pins: n x y, ...; boxes: x y w h, ...; address: ..."). Null when it is not one. */
export function parseImage(line: string): GuideImage | null {
  const m = /^!\[([^\]]*)\]\(([^)\s"]+)(?:\s+"([^"]*)")?\)$/.exec(line.trim());
  if (!m) return null;
  const src = m[2]!;
  if (!SAFE_URL.test(src) || src.startsWith('#')) return null;
  const img: GuideImage = { src, alt: m[1] ?? '', phone: false, pins: [], boxes: [] };
  for (const part of (m[3] ?? '').split(';').map((x) => x.trim()).filter(Boolean)) {
    const [k, ...rest] = part.split(':');
    const key = k!.trim().toLowerCase();
    const v = rest.join(':').trim();
    if (!rest.length) { if (key === 'phone') img.phone = true; continue; }
    if (key === 'size') { const [w, h] = v.split(/\s+/).map(Number); if (w! > 0 && h! > 0) { img.width = w; img.height = h; } }
    else if (key === 'address') img.address = v;
    else if (key === 'pins') {
      for (const p of v.split(',')) { const [n, x, y] = p.trim().split(/\s+/); const fx = Number(x), fy = Number(y); if (n && Number.isFinite(fx) && Number.isFinite(fy)) img.pins.push({ n: n.slice(0, 3), x: clamp(fx), y: clamp(fy) }); }
    } else if (key === 'boxes') {
      for (const p of v.split(',')) { const [x, y, w, h] = p.trim().split(/\s+/).map(Number); if ([x, y, w, h].every((q) => Number.isFinite(q))) img.boxes.push({ x: clamp(x!), y: clamp(y!), w: clamp(w!), h: clamp(h!) }); }
    }
  }
  return img;
}
const clamp = (n: number) => Math.min(100, Math.max(0, Math.round(n * 10) / 10));

export function imageHtml(img: GuideImage, caption?: string): string {
  const ratio = img.width && img.height ? ` style="aspect-ratio:${img.width}/${img.height}"` : '';
  const dims = img.width && img.height ? ` width="${img.width}" height="${img.height}"` : '';
  const overlays = img.boxes.map((b) => `<span class="gd-hl" style="left:${b.x}%;top:${b.y}%;width:${b.w}%;height:${b.h}%"></span>`).join('')
    + img.pins.map((p) => `<span class="gd-pin" style="left:${p.x}%;top:${p.y}%" aria-hidden="true">${esc(p.n)}</span>`).join('');
  const inner = `<div class="gd-imgwrap"${ratio}><img src="${esc(img.src)}" alt="${esc(img.alt)}" loading="lazy" decoding="async"${dims}>${overlays}</div>`;
  const frame = img.phone ? `<div class="gd-phone">${inner}</div>`
    : `<div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i>${img.address ? `<span class="gd-addr">${esc(img.address)}</span>` : ''}</div>${inner}</div>`;
  const cap = caption ?? img.alt;
  return `<figure class="gd-fig ${img.phone ? 'gd-fig--phone' : 'gd-fig--desk'}">${frame}${cap ? `<figcaption>${inline(cap)}</figcaption>` : ''}</figure>`;
}

const BOX = /^(tip|good to know|note|remember|watch out|important)\s*:\s*/i;
const OL = /^(\d{1,3})\.\s+(.*)$/;
const UL = /^[-*]\s+(.*)$/;

type Block =
  | { t: 'h2' | 'h3' | 'p'; text: string }
  | { t: 'ol'; start: number; items: string[] }
  | { t: 'ul'; items: string[] }
  | { t: 'img'; img: GuideImage; line: string }
  | { t: 'box'; label: string | null; text: string }
  | { t: 'table'; head: string[]; rows: string[][] }
  | { t: 'flow'; items: Array<[string, string]> }
  | { t: 'phones'; items: Array<{ n: string; caption: string; img: GuideImage | null }> };

function cells(line: string): string[] {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

export function parse(md: string, warnings: string[] = []): Block[] {
  const lines = md.replace(/\r\n?/g, '\n').split('\n');
  const out: Block[] = [];
  let i = 0;
  const blank = (l: string | undefined) => l === undefined || l.trim() === '';
  while (i < lines.length) {
    const line = lines[i]!;
    const t = line.trim();
    if (!t) { i++; continue; }
    if (/^:::(flow|phones)\s*$/.test(t)) {
      const kind = t.slice(3).trim() as 'flow' | 'phones';
      const body: string[] = [];
      i++;
      while (i < lines.length && lines[i]!.trim() !== ':::') { if (lines[i]!.trim()) body.push(lines[i]!.trim()); i++; }
      if (i >= lines.length) warnings.push(`A :::${kind} block is not closed with :::`);
      i++;
      if (kind === 'flow') out.push({ t: 'flow', items: body.map((b) => { const [a, ...rest] = b.split('|'); return [a!.trim(), rest.join('|').trim()] as [string, string]; }) });
      else out.push({ t: 'phones', items: body.map((b, k) => {
        const m = OL.exec(b);
        const text = m ? m[2]! : b;
        const im = /!\[[^\]]*\]\([^)]*\)\s*$/.exec(text);
        const img = im ? parseImage(im[0]) : null;
        if (im && !img) warnings.push(`An image in :::phones could not be read: ${im[0].slice(0, 80)}`);
        return { n: m ? m[1]! : String(k + 1), caption: (im ? text.slice(0, im.index) : text).trim(), img };
      }) });
      continue;
    }
    if (t.startsWith('### ')) { out.push({ t: 'h3', text: t.slice(4).trim() }); i++; continue; }
    if (t.startsWith('## ')) { out.push({ t: 'h2', text: t.slice(3).trim() }); i++; continue; }
    if (t.startsWith('# ')) { out.push({ t: 'h2', text: t.slice(2).trim() }); i++; continue; }
    if (t.startsWith('>')) {
      const body: string[] = [];
      while (i < lines.length && lines[i]!.trim().startsWith('>')) { body.push(lines[i]!.trim().replace(/^>\s?/, '')); i++; }
      const text = body.join(' ').trim();
      const m = BOX.exec(text);
      out.push({ t: 'box', label: m ? m[1]! : null, text: m ? text.slice(m[0].length) : text });
      continue;
    }
    if (t.startsWith('|') && i + 1 < lines.length && /^\|?\s*:?-{2,}/.test(lines[i + 1]!.trim())) {
      const head = cells(t);
      const rows: string[][] = [];
      i += 2;
      while (i < lines.length && lines[i]!.trim().startsWith('|')) { rows.push(cells(lines[i]!)); i++; }
      out.push({ t: 'table', head, rows });
      continue;
    }
    const img = t.startsWith('![') ? parseImage(t) : null;
    if (img) { out.push({ t: 'img', img, line: t }); i++; continue; }
    if (t.startsWith('![')) warnings.push(`An image could not be read: ${t.slice(0, 80)}`);
    const ol = OL.exec(t);
    if (ol) {
      const items: string[] = [];
      const start = Number(ol[1]);
      while (i < lines.length) {
        const l = lines[i]!;
        const m = OL.exec(l.trim());
        if (m && !/^\s{2,}/.test(l)) { items.push(m[2]!); i++; continue; }
        if (!blank(l) && /^\s{2,}/.test(l) && items.length) { items[items.length - 1] += ' ' + l.trim(); i++; continue; }
        break;
      }
      out.push({ t: 'ol', start, items });
      continue;
    }
    if (UL.test(t)) {
      const items: string[] = [];
      while (i < lines.length) {
        const l = lines[i]!;
        const m = UL.exec(l.trim());
        if (m && !/^\s{2,}/.test(l)) { items.push(m[1]!); i++; continue; }
        if (!blank(l) && /^\s{2,}/.test(l) && items.length) { items[items.length - 1] += ' ' + l.trim(); i++; continue; }
        break;
      }
      out.push({ t: 'ul', items });
      continue;
    }
    const para: string[] = [];
    while (i < lines.length && !blank(lines[i]) && !/^(#{1,3} |>|\||:::|!\[)/.test(lines[i]!.trim()) && !OL.test(lines[i]!.trim()) && !UL.test(lines[i]!.trim())) {
      para.push(lines[i]!.trim()); i++;
    }
    if (para.length) out.push({ t: 'p', text: para.join(' ') });
    else { out.push({ t: 'p', text: t }); i++; }
  }
  return out;
}

function olHtml(b: { start: number; items: string[] }): string {
  return `<ol class="gd-ol"${b.start !== 1 ? ` start="${b.start}"` : ''}>${b.items.map((it, k) => `<li><span class="gd-n" aria-hidden="true">${b.start + k}</span><div class="gd-t">${inline(it)}</div></li>`).join('')}</ol>`;
}

/** Render one section's Markdown. idPrefix keeps the task anchors unique across the guide. */
export function render(md: string, opts: { idPrefix?: string } = {}): RenderResult {
  const warnings: string[] = [];
  const blocks = parse(md, warnings);
  const tasks: RenderResult['tasks'] = [];
  const images: string[] = [];
  const used = new Set<string>();
  const parts: string[] = [];
  let open = false;
  const close = () => { if (open) { parts.push('</section>'); open = false; } };
  for (let k = 0; k < blocks.length; k++) {
    const b = blocks[k]!;
    switch (b.t) {
      case 'h2': {
        close();
        let id = `${opts.idPrefix ? opts.idPrefix + '-' : ''}${slugify(b.text)}`;
        let n = 2;
        while (used.has(id)) id = `${id.replace(/-\d+$/, '')}-${n++}`;
        used.add(id);
        tasks.push({ id, title: b.text.replace(/\*\*|`/g, '') });
        parts.push(`<section class="gd-task" id="${esc(id)}" data-gd-task><h2 class="gd-h2">${inline(b.text)}</h2>`);
        open = true;
        break;
      }
      case 'h3': parts.push(`<h3 class="gd-h3">${inline(b.text)}</h3>`); break;
      case 'p': parts.push(`<p class="gd-p">${inline(b.text)}</p>`); break;
      case 'ul': parts.push(`<ul class="gd-ul">${b.items.map((it) => `<li>${inline(it)}</li>`).join('')}</ul>`); break;
      case 'ol': {
        const next = blocks[k + 1];
        if (next && next.t === 'img') {
          images.push(next.img.src);
          parts.push(`<div class="gd-stepblock ${next.img.phone ? 'gd-stepblock--side' : 'gd-stepblock--below'}"><div class="gd-stepcol">${olHtml(b)}</div>${imageHtml(next.img, '')}</div>`);
          k++;
        } else parts.push(`<div class="gd-stepblock">${olHtml(b)}</div>`);
        break;
      }
      case 'img': images.push(b.img.src); parts.push(`<div class="gd-figblock">${imageHtml(b.img)}</div>`); break;
      case 'box': {
        const warn = !!b.label && /watch out|important/i.test(b.label);
        parts.push(`<aside class="gd-box${warn ? ' gd-box--warn' : ''}">${b.label ? `<span class="gd-lbl">${esc(b.label)}</span>` : ''}<div>${inline(b.text)}</div></aside>`);
        break;
      }
      case 'table': {
        const hasHead = b.head.some((h) => h);
        parts.push(`<div class="gd-tablewrap"><table class="gd-table">${hasHead ? `<thead><tr>${b.head.map((h) => `<th scope="col">${inline(h)}</th>`).join('')}</tr></thead>` : ''}<tbody>${b.rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`);
        break;
      }
      case 'flow': parts.push(`<ol class="gd-flow">${b.items.map(([a, d], n) => `<li><b>${n + 1}</b><span>${inline(a)}</span><em>${inline(d)}</em></li>`).join('')}</ol>`); break;
      case 'phones': {
        b.items.forEach((x) => { if (x.img) images.push(x.img.src); });
        parts.push(`<div class="gd-phones">${b.items.map((x) => `<div class="gd-pcell"><div class="gd-pcap"><span class="gd-n" aria-hidden="true">${esc(x.n)}</span><div>${inline(x.caption)}</div></div>${x.img ? imageHtml(x.img, '') : ''}</div>`).join('')}</div>`);
        break;
      }
    }
  }
  close();
  return { html: parts.join(''), tasks, images, warnings };
}

export interface GuideSectionInput { id: string; slug: string; kind: string; title: string; body_md: string }
/** Every section of a guide, for publishing: the HTML per section id, and what to fix first. */
export function renderGuide(sections: GuideSectionInput[]): { html: Record<string, string>; warnings: string[] } {
  const html: Record<string, string> = {};
  const warnings: string[] = [];
  for (const s of sections) {
    const r = render(s.body_md, { idPrefix: s.slug });
    html[s.id] = r.html;
    for (const w of r.warnings) warnings.push(`${s.title}: ${w}`);
  }
  return { html, warnings };
}
