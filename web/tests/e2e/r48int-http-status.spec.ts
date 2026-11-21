import { test, expect } from '@playwright/test';

// R48 integration: a missing public page is a real 404 and a redirect a real 3xx, never a soft 404 or a meta refresh
// streamed as 200 (a segment loading.tsx makes a page's notFound() and redirect() stream; the public routes have none,
// and the staff portals' sign-in redirect is answered at the edge, src/lib/edge/portal-gate.ts).
test.use({ storageState: { cookies: [], origins: [] } });

test('missing public pages answer 404; redirects answer 3xx with a location', async ({ request }) => {
  for (const path of ['/cars/no-such-car-r48int', '/car-rental/no-such-place-r48int', '/events/no-such-event-r48int', '/trackers/no-such-tracker-r48int']) {
    const r = await request.get(path, { maxRedirects: 0 });
    expect(r.status(), path).toBe(404);
  }
  const old = await request.get('/gps-tracker', { maxRedirects: 0 });
  expect(old.status()).toBe(308);
  expect(old.headers().location).toMatch(/\/trackers$/);
  for (const path of ['/admin/bookings', '/staff']) {
    const r = await request.get(path, { maxRedirects: 0 });
    expect([302, 303, 307, 308], path).toContain(r.status());
    expect(r.headers().location, path).toMatch(/\/sign-in\?next=/);
    expect(await r.text(), path).not.toMatch(/http-equiv="refresh"/i);
  }
});
