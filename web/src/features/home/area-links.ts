// 2350 (the owner: "Search Console insane"): home, the site's strongest page, links to the money pages: every indexable
// location landing page (Toronto first, then the GTA by name) and the indexable use pages (SUV rental, monthly rental ...).
// Only real, indexable landing pages: never a place page without its own content. Pure, tested in Node.
export interface AreaPage { slug: string; kind: 'location' | 'use'; name: string; path: string; indexable: boolean }
export function homeAreaLinks(pages: AreaPage[], max = { places: 24, uses: 12 }): { places: AreaPage[]; uses: AreaPage[] } {
  const ok = pages.filter((p) => p.indexable && /^\/car-rental\/[a-z0-9-]+$/.test(p.path));
  const name = (p: AreaPage) => p.name.replace(/ \(.*\)$/, '');
  const places = ok.filter((p) => p.kind === 'location')
    .sort((a, b) => Number(/^toronto/i.test(name(b))) - Number(/^toronto/i.test(name(a))) || name(a).localeCompare(name(b)))
    .slice(0, max.places);
  const uses = ok.filter((p) => p.kind === 'use').sort((a, b) => a.name.localeCompare(b.name)).slice(0, max.uses);
  return { places, uses };
}
