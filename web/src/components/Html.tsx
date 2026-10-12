// Editable copy from site_content_blocks may carry simple links and emphasis (written by staff in
// the admin portal, never by visitors). Only <a href="/..."> or https links, <b>, <strong> and <em>
// survive; everything else is escaped.
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export function safeInline(html: string): string {
  const keep: string[] = [];
  const marked = html.replace(/<a class="link" href="(\/[^"]*|https:\/\/[^"]*)">([^<]*)<\/a>|<(\/?)(b|strong|em)>/g, (m, href: string | undefined, text: string | undefined, close: string | undefined, tag: string | undefined) => {
    keep.push(href ? `<a class="link" href="${esc(href)}">${esc(text ?? '')}</a>` : `<${close}${tag}>`);
    return `\u0000${keep.length - 1}\u0000`;
  });
  return esc(marked).replace(/\u0000(\d+)\u0000/g, (_, i: string) => keep[Number(i)]!);
}
export function Html({ html, as: Tag = 'span', className }: { html: string; as?: 'span' | 'p' | 'div'; className?: string }) {
  return <Tag className={className} dangerouslySetInnerHTML={{ __html: safeInline(html) }} />;
}
