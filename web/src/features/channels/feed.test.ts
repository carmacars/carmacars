import { test } from 'node:test';
import assert from 'node:assert/strict';
import { csv, row, shared, xml, type ChannelCar } from './feed.ts';

const car = (over: Partial<ChannelCar> = {}): ChannelCar => ({ vehicle_id: 'v1', car_code: 'C1', supply_type: 'company', name: '2024 BMW X5 "M"', year: 2024, make: 'BMW', model: 'X5', trim: null,
  colour: 'Black', class: 'suv', seats: '5', doors: 4, body_style: 'SUV', transmission: 'Automatic', location: 'Toronto', car_url: 'https://carmacars.ca/cars/bmw-x5',
  photos: ['a.jpg', 'b.jpg'], daily_cents: 18900, weekly_cents: 113400, monthly_cents: 378000, deposit_cents: 50000, km_per_day: '200',
  availability: { available_today: true, next_free_date: null, free_days_30: 20 }, ...over });

test('never a partner car', () => {
  assert.deepEqual(shared([car(), car({ supply_type: 'partner' }), car({ supply_type: 'program_owner' })]).map((c) => c.supply_type), ['company', 'program_owner']);
  assert.deepEqual(shared([car({ car_url: null as unknown as string }), car({ photos: null as unknown as string[] })]).length, 1, 'a car with no page is left out; one with no photos stays');
});
test('a row: dollars, the tracked link, photos', () => {
  const r = row(car(), 'kayak', (p) => `https://img/${p}`);
  assert.equal(r.daily_rate_cad, 189);
  assert.match(String(r.link), /utm_source=kayak/);
  assert.equal(r.image_link, 'https://img/a.jpg');
});
test('CSV quotes and XML escapes', () => {
  const r = row(car(), 'meta_catalog', (p) => p);
  assert.match(csv([r]), /"2024 BMW X5 ""M"""/);
  const s = xml([r], { url: 'https://carmacars.ca', name: 'CarmaCars', city: 'Toronto' });
  assert.match(s, /<g:price>189\.00 CAD<\/g:price>/);
  assert.match(s, /&quot;M&quot;/);
  assert.ok(!s.includes('"M"'));
});
