// The embeddable inventory widget (migration 0147): a plain HTML page of our cars for a partner's GoHighLevel funnel or
// site (an iframe), with no script at all. Each card opens the car's booking link (with the partner's code) in a new tab.
// No imports: Worker and `node --test`.
import type { OutboundCar } from './mapping.ts';

const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const money = (c: number | null) => (c === null || c === undefined ? null : `$${Math.round(c / 100).toLocaleString('en-CA')}`);

export interface WidgetOptions { title: string; siteName: string; photos: (car: OutboundCar) => string[]; compact?: boolean }

export function renderWidget(cars: OutboundCar[], o: WidgetOptions): string {
  const cards = cars.map((c) => {
    const ph = o.photos(c)[0];
    const a = c.availability;
    const avail = !a ? '' : a.available_today ? 'Available today' : a.next_free_date ? `Next free ${esc(a.next_free_date)}` : 'Booked for the next 60 days';
    const day = money(c.daily_cents);
    return `<li class="card"><a href="${esc(c.book_url)}" target="_blank" rel="noopener">`
      + (ph ? `<img src="${esc(ph)}" alt="${esc(c.name)}" loading="lazy" width="640" height="400">` : `<span class="noimg" aria-hidden="true"></span>`)
      + `<span class="body"><span class="name">${esc(c.name)}</span>`
      + `<span class="meta">${esc([c.class, c.seats ? `${c.seats} seats` : null, c.transmission].filter(Boolean).join(' · '))}</span>`
      + `<span class="row">${day ? `<span class="price">${esc(day)}<small> a day</small></span>` : '<span class="price">Rate on request</span>'}`
      + (avail ? `<span class="avail${a?.available_today ? ' ok' : ''}">${avail}</span>` : '') + `</span>`
      + `<span class="cta">Book on ${esc(o.siteName)}</span></span></a></li>`;
  }).join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow">`
    + `<title>${esc(o.title)}</title><style>`
    + `:root{color-scheme:light dark;--bg:#fff;--fg:#14161a;--muted:#5b616b;--line:#e3e5e8;--accent:#0b5cad;--ok:#0f7b3f}`
    + `@media (prefers-color-scheme:dark){:root{--bg:#121417;--fg:#f2f3f5;--muted:#a6acb5;--line:#2a2e34;--accent:#7db7ff;--ok:#5fd394}}`
    + `*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}`
    + `ul{list-style:none;margin:0;padding:12px;display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(240px,1fr))}`
    + `.card a{display:flex;flex-direction:column;height:100%;border:1px solid var(--line);border-radius:12px;overflow:hidden;color:inherit;text-decoration:none}`
    + `.card a:focus-visible{outline:3px solid var(--accent);outline-offset:2px}img,.noimg{display:block;width:100%;aspect-ratio:16/10;object-fit:cover;background:var(--line)}`
    + `.body{display:flex;flex-direction:column;gap:4px;padding:12px;flex:1}.name{font-weight:600}.meta{color:var(--muted);font-size:13px;text-transform:capitalize}`
    + `.row{display:flex;justify-content:space-between;align-items:baseline;gap:8px;flex-wrap:wrap;margin-top:auto}.price{font-weight:600}.price small{font-weight:400;color:var(--muted)}`
    + `.avail{font-size:13px;color:var(--muted)}.avail.ok{color:var(--ok)}.cta{margin-top:8px;color:var(--accent);font-weight:600;font-size:14px}`
    + `p.empty{padding:24px;color:var(--muted);text-align:center}`
    + `</style></head><body>`
    + (cars.length ? `<ul aria-label="${esc(o.title)}">${cards}</ul>` : `<p class="empty">No cars to show right now.</p>`)
    + `</body></html>`;
}
