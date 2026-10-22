import { test } from '@playwright/test';
import postgres from 'postgres';
import { randomUUID, randomBytes, scryptSync } from 'node:crypto';
test('hydration', async ({ browser }) => {
  const sql = postgres('postgresql://postgres@127.0.0.1:54389/carmacars', { max: 1 });
  const id = randomUUID(); const email = `h.${Date.now()}@example.test`; const salt = randomBytes(16);
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${`scrypt$${salt.toString('base64')}$${scryptSync('correct horse battery', salt, 64).toString('base64')}`})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'H')`; await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const [car] = await sql`select vehicle_id from vehicle_service_items limit 1`;
  const p = await (await browser.newContext({ baseURL: 'http://localhost:3089', timezoneId: 'America/Toronto' })).newPage();
  p.on('console', (m) => { if (m.type() === 'error') console.log('CONSOLE', m.text().slice(0, 1500)); });
  p.on('pageerror', (e) => console.log('PAGEERR', String(e).slice(0, 1500)));
  await p.goto('/sign-in'); await p.locator('input[type="email"]').fill(email); await p.locator('input[type="password"]').fill('correct horse battery');
  await p.getByRole('button', { name: 'Sign in' }).click(); await p.waitForURL((x) => x.pathname.startsWith('/admin'));
  await p.goto(`/admin/vehicles/${car!.vehicle_id}?tab=maintenance`, { waitUntil: 'networkidle' }); await p.waitForTimeout(3000);
  await sql.end();
});
