import { expect, test } from '@playwright/test';

// 0102: /sitemap.xml is the one address to submit. It is a <sitemapindex> naming every child sitemap: the site's own
// files (pages, cars, landing, guides and the model pages), the place files of 0095 and the vehicle files of 0097. Each
// child is a <urlset> under 50,000 addresses, built from the database without rendering pages. robots.txt names them
// too. Followed here down to a real vehicle page and a real place page.
const locs = (xml: string) => [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]!.replace(/&amp;/g, '&'));
const pathOf = (u: string) => { const x = new URL(u); return x.pathname + x.search; };

test('the sitemap index leads to every child sitemap, a vehicle page and a place page', async ({ request }) => {
  test.skip(test.info().project.name !== 'desktop-1440', 'one width is enough for files');
  test.setTimeout(120_000);
  const res = await request.get('/sitemap.xml');
  expect(res.status()).toBe(200);
  const idx = await res.text();
  expect(idx).toMatch(/^<\?xml[^>]*>\s*<sitemapindex xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9">/);
  expect(idx).not.toContain('<urlset');
  const children = locs(idx).map(pathOf);
  for (const part of ['pages', 'cars', 'landing', 'guides', 'hubs']) expect(children).toContain(`/sitemap-${part}.xml`);
  const place = children.find((p) => p.startsWith('/sitemap-places-'));
  const vehicle = children.find((p) => p.startsWith('/sitemap-vehicles-'));
  expect(place, 'a place file (0095)').toBeTruthy();
  expect(vehicle, 'a vehicle file (0097)').toBeTruthy();
  expect(children.length).toBeLessThanOrEqual(50_000);

  // every child of the site's own is a urlset of public pages under 50,000 addresses
  for (const p of children.filter((c) => /^\/sitemap-[a-z]+\.xml$/.test(c))) {
    const xml = await (await request.get(p)).text();
    expect(xml, p).toContain('<urlset');
    expect(locs(xml).length, p).toBeLessThan(50_000);
  }
  // the model pages are listed (and open)
  const hubs = locs(await (await request.get('/sitemap-hubs.xml')).text()).map(pathOf);
  expect(hubs.length).toBeGreaterThan(0);
  expect(hubs.every((h) => /^\/cars\/[a-z0-9-]+\/[a-z0-9-]+$/.test(h))).toBe(true);
  expect((await request.get(hubs[0]!)).status()).toBe(200);

  // down to a place page
  const placeXml = await (await request.get(place!)).text();
  expect(placeXml).toContain('<urlset');
  const placeUrl = locs(placeXml).map(pathOf)[0];
  expect(placeUrl, 'a place page in the place file').toBeTruthy();
  expect((await request.get(placeUrl!)).status()).toBe(200);

  // down to a vehicle page: the first vehicle file with addresses
  let vehicleUrl: string | undefined;
  for (const v of children.filter((c) => c.startsWith('/sitemap-vehicles-')).slice(0, 20)) {
    const r = await request.get(v);
    if (r.status() !== 200) continue;
    const xml = await r.text();
    expect(xml).toContain('<urlset');
    vehicleUrl = locs(xml).map(pathOf)[0];
    if (vehicleUrl) break;
  }
  expect(vehicleUrl, 'a vehicle page in a vehicle file').toBeTruthy();
  expect((await request.get(vehicleUrl!)).status()).toBe(200);

  // robots.txt names the index and its children
  const robots = await (await request.get('/robots.txt')).text();
  expect(robots).toMatch(/Sitemap: \S+\/sitemap\.xml/);
  expect(robots).toMatch(/Sitemap: \S+\/sitemap-hubs\.xml/);
  expect(robots).toMatch(/Sitemap: \S+\/sitemap-places-\S+\.xml/);
});
