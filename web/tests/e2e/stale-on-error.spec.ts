import { expect, test, type APIRequestContext } from '@playwright/test';

// The site stays up when the database is slow (0106; src/lib/edge/page-cache.ts serveEdge, used by the Worker entry and
// by scripts/serve.mjs). A car page served once is kept as its last good copy; when the app then answers 500 for it (the
// database busy with an import), the visitor still gets the page, marked x-edge-stale, never "Internal server error".
// A page with no copy yet gets the busy page that retries by itself; a signed-in visitor always reaches the app.
const CAR = '/cars/tesla-model-3';
const fault = (request: APIRequestContext, path: string, status: number) => request.post('/__test/fault', { data: { path, status } });

test.afterEach(async ({ request }) => { await fault(request, CAR, 0); await fault(request, '/cars/no-copy-yet-e2e', 0); });

test('a car page served once is still served when the app answers 500', async ({ page, request }) => {
  // served once: the good answer is kept
  const first = await page.goto(CAR);
  expect(first!.status()).toBe(200);
  const title = await page.locator('h1').first().innerText();
  expect(first!.headers()['x-edge-stale']).toBeUndefined();

  // the app now answers 500 for this page
  expect((await fault(request, CAR, 500)).ok()).toBe(true);
  const direct = await request.get(CAR, { headers: { accept: 'text/html', cookie: 'sb-e2etest-auth-token=base64-x' } });
  expect(direct.status(), 'a session reaches the app: the 500 itself').toBe(500);

  // a visitor still gets the page, from the last good copy
  const again = await page.goto(CAR);
  expect(again!.status()).toBe(200);
  expect(again!.headers()['x-edge-stale']).toMatch(/^error 500; age=\d+/);
  expect(again!.headers()['cache-control']).toBe('no-cache');
  await expect(page.locator('h1').first()).toHaveText(title);
  await expect(page.getByText(/internal server error/i)).toHaveCount(0);
  // the page works: its scripts carry this response's nonce
  const nonce = /'nonce-([^']+)'/.exec(again!.headers()['content-security-policy'] ?? '')?.[1];
  expect(nonce).toBeTruthy();
  expect(await again!.text()).toContain(`<script nonce="${nonce}"`);

  // the app answers again: the real page, not the copy
  await fault(request, CAR, 0);
  await expect.poll(async () => (await request.get(CAR, { headers: { accept: 'text/html' } })).headers()['x-edge-stale'] ?? 'fresh', { timeout: 20_000 }).toBe('fresh');
});

test('a page never served before: the busy page that retries, not a raw 500', async ({ page, request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  await fault(request, '/cars/no-copy-yet-e2e', 500);
  const r = await page.goto('/cars/no-copy-yet-e2e');
  expect(r!.status()).toBe(503);
  expect(r!.headers()['retry-after']).toBe('5');
  await expect(page.getByRole('heading', { name: 'Busy for a moment, retrying' })).toBeVisible();
  await expect(page.getByText(/Trying again in \d+ seconds/)).toBeVisible();
  // it retries by itself: once the app answers, the visitor lands on the real answer (a 404 here: no such car)
  await fault(request, '/cars/no-copy-yet-e2e', 0);
  await expect(page.getByRole('heading', { name: 'Busy for a moment, retrying' })).toHaveCount(0, { timeout: 15_000 });
});
