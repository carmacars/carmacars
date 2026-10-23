import { expect, test, type Page } from '@playwright/test';
import { noOverflow } from './helpers';

// AI search (docs/changes/2026-10-23-ai-search.md): robots.txt names the AI answer engines and keeps the private paths
// out; /llms.txt and /llms-full.txt answer from the database; /about is the facts page; the key pages open with the
// short answer; every page carries the business node; the mechanical work we arrange carries no Service, FAQ or price.
const ld = async (page: Page) => (await page.locator('script[type="application/ld+json"]').allTextContents())
  .flatMap((s) => { const j = JSON.parse(s) as { '@graph'?: Record<string, unknown>[] }; return j['@graph'] ?? [j as Record<string, unknown>]; });
const types = (nodes: Record<string, unknown>[]) => nodes.flatMap((n) => ([] as unknown[]).concat(n['@type'] ?? []) as string[]);

test('robots.txt: the AI and search crawlers by name, the same private paths for them and for everyone', async ({ request }) => {
  const r = await (await request.get('/robots.txt')).text();
  for (const b of ['OAI-SearchBot', 'ChatGPT-User', 'GPTBot', 'ClaudeBot', 'Claude-SearchBot', 'Claude-User', 'PerplexityBot', 'Perplexity-User', 'Google-Extended',
    'Applebot-Extended', 'Bingbot', 'DuckDuckBot', 'Amazonbot', 'Meta-ExternalAgent', 'CCBot', 'YandexBot']) expect(r, b).toMatch(new RegExp(`^User-Agent: ${b}$`, 'mi'));
  const groups = r.split(/\n\s*\n/).filter((g) => /User-Agent:/i.test(g));
  expect(groups.length).toBeGreaterThanOrEqual(2);
  for (const g of groups) for (const p of ['/admin', '/account', '/owner', '/api/', '/sign-in']) expect(g, p).toContain(`Disallow: ${p}\n`);
  expect(r).toMatch(/Sitemap: \S+\/sitemap\.xml/);
});

test('llms.txt and llms-full.txt: plain text from the database, the phone, the address and the key pages', async ({ request }) => {
  const a = await request.get('/llms.txt');
  expect(a.status()).toBe(200);
  expect(a.headers()['content-type']).toContain('text/plain');
  const t = await a.text();
  expect(t).toMatch(/^# CarmaCars\n\n> CarmaCars is a car rental company in /);
  expect(t).toContain('289-312-5991');
  for (const h of ['## Services', '## Locations served', '## Policies and help']) expect(t).toContain(h);
  expect(t).toMatch(/\]\(https?:\/\/[^)]+\/about\)/);
  expect(t).not.toMatch(/\{\{|[–—]/);
  const full = await (await request.get('/llms-full.txt')).text();
  for (const h of ['## Contact', '## Fleet and prices', '## Renting', '## Questions', '- Cancellation: ']) expect(full).toContain(h);
  expect(full).not.toMatch(/\{\{|<a |[–—]/);
});

test('/about: the facts page, its short answer, AboutPage and the business node, no overflow on a phone', async ({ page }) => {
  await page.goto('/about');
  await expect(page.locator('h1')).toHaveText('About CarmaCars');
  await expect(page.getByTestId('answer-block')).toContainText('289-312-5991');
  await expect(page.getByTestId('answer-lead')).toContainText('car rental company in');
  const nodes = await ld(page);
  for (const x of ['AboutPage', 'BreadcrumbList', 'AutoRental', 'WebSite']) expect(types(nodes), x).toContain(x);
  await noOverflow(page);
});

for (const path of ['/', '/car-rental', '/car-rental/toronto', '/chauffeur', '/delivery', '/detailing', '/body-shop']) {
  test(`the short answer opens ${path}`, async ({ page }) => {
    await page.goto(path);
    const block = page.getByTestId('answer-block');
    await expect(block).toBeVisible();
    await expect(block).toContainText('289-312-5991');
    // a date only when one is real, and then a valid one
    const when = block.locator('time');
    if (await when.count()) expect(await when.getAttribute('datetime')).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    const biz = (await ld(page)).find((n) => types([n]).includes('AutoRental')) as { telephone?: string; contactPoint?: unknown[] } | undefined;
    expect(biz?.telephone).toBeTruthy();
    expect(biz?.contactPoint?.length).toBeGreaterThan(0);
    await noOverflow(page);
  });
}

test('every page resolves #business: the guides and the policies carry the node too', async ({ page }) => {
  for (const path of ['/guides', '/faq', '/terms']) {
    await page.goto(path);
    const nodes = await ld(page);
    expect(nodes.some((n) => n['@id'] && String(n['@id']).endsWith('/#business') && types([n]).includes('AutoRental')), path).toBe(true);
  }
});

test('the mechanical work we arrange: no Service, no FAQ, no price in the structured data', async ({ page }) => {
  const res = await page.goto('/body-shop/towing/toronto');
  test.skip(res?.status() === 404, 'no places loaded');
  const nodes = await ld(page);
  const t = types(nodes);
  expect(t).not.toContain('Service');
  expect(t).not.toContain('FAQPage');
  expect(JSON.stringify(nodes.filter((n) => !types([n]).includes('AutoRental')))).not.toMatch(/"price"|"offers"/);
});
