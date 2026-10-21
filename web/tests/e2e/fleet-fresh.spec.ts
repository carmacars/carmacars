import { expect, test } from '@playwright/test';
import { randomBytes, randomUUID } from 'node:crypto';
import { db } from './helpers';

// A car put on and taken off the site in the database alone (0070's automatic publishing, a fixture unpublished by
// SQL) reaches the fleet page, home and the cars sitemap without any app action:
// scripts/serve.mjs, like the Worker's cron tick, rebuilds the public pages when the fleet's signature changes
// (src/lib/edge/fleet-sig.ts, /api/jobs/public-rebuild). The deploy run of October 21, 2026 failed on the SEO audit and
// the crawl because the fleet page still linked such cars.
const tag = () => randomBytes(3).toString('hex');
const vin = () => `3FF${randomBytes(7).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');

test('a car published and taken off in the database alone leaves no stale link on the fleet page, home or the sitemap', async ({ request }, info) => {
  test.skip(info.project.name.startsWith('phone'), 'once is enough');
  test.setTimeout(150_000);
  const sql = db();
  try {
    const admin = randomUUID();
    await sql`insert into users (id, email, full_name) values (${admin}, ${`admin.ff.${Date.now()}.${tag()}@example.test`}, 'Ff Admin')`;
    await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
    // the fleet page is in the page cache before the change
    await request.get('/cars'); await request.get('/');
    const [s] = await sql`select app.vehicle_add(${admin}, ${sql.json({ supply_type: 'company', vin: vin(), plate: `FF${tag().toUpperCase()}`, year: 2024, make: 'Mazda', model: `CX-5 ${tag()}`, rates: { daily: 6500 } })}) as r`;
    const car = (s!.r as { vehicle_id: string }).vehicle_id;
    // published by itself (Program setting "Publish new cars automatically", 0070); published here if the setting is off
    await sql`update vehicle_listings set status = 'published' where vehicle_id = ${car} and status <> 'published'`;
    const slugOf = async () => (await sql`select slug from vehicle_listings where vehicle_id = ${car}`)[0]!.slug as string;
    const links = async (path: string) => (await (await request.get(path)).text());
    const slug = await slugOf();
    await expect.poll(async () => (await links('/cars')).includes(`href="/cars/${slug}"`), { timeout: 45_000, intervals: [2_000] }).toBe(true);

    // off the site in the database alone: gone from the fleet page, home and the cars sitemap
    await sql`update vehicle_listings set status = 'unpublished', unpublished_at = now(), unpublished_reason = 'e2e fixture' where vehicle_id = ${car}`;
    await expect.poll(async () => (await links('/cars')).includes(`/cars/${slug}"`), { timeout: 45_000, intervals: [2_000] }).toBe(false);
    expect((await links('/')).includes(`/cars/${slug}"`)).toBe(false);
    expect((await links('/sitemap-cars.xml')).includes(`/cars/${slug}<`)).toBe(false);
  } finally { await sql.end(); }
});
