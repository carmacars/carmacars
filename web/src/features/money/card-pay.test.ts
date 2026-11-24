// Hotfix 3650: card payments on or off, and paying by e-Transfer when they are off.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { amountFor, cardOn, cardPausedWhy, coversFor, etransferMessage, etransferParts } from './card-pay.ts';

const fmt = (c: number) => `$${(c / 100).toFixed(2)}`;
const read = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');
const SQL = read('../../../../supabase/migrations/3650_hotfix_card_off.sql');

test('cards are on unless the state says off; a state that could not be read keeps them', () => {
  assert.equal(cardOn({ on: true }), true);
  assert.equal(cardOn({ on: false }), false);
  assert.equal(cardOn(null), true);
  assert.equal(cardOn(undefined), true);
});

test('why cards are paused, in words', () => {
  assert.match(cardPausedWhy({ reason: 'setting' }), /Program settings/);
  assert.match(cardPausedWhy({ reason: 'processor' }), /processor/);
  assert.match(cardPausedWhy(null), /processor/);
});

test('what the renter sends by e-Transfer: the rental and the e-Transfer deposit; cash stays cash', () => {
  assert.deepEqual(etransferParts({ rental_cents: 50000, rental_cash: false, deposit_cents: 60000, deposit_method: 'e_transfer' }),
    { rental: 50000, deposit: 60000, total: 110000, cashRental: 0, cashDeposit: 0 });
  assert.deepEqual(etransferParts({ rental_cents: 50000, rental_cash: true, deposit_cents: 60000, deposit_method: 'cash' }),
    { rental: 0, deposit: 0, total: 0, cashRental: 50000, cashDeposit: 60000 });
  assert.deepEqual(etransferParts({ rental_cents: 0, rental_cash: false, deposit_cents: 60000, deposit_method: 'e_transfer' }),
    { rental: 0, deposit: 60000, total: 60000, cashRental: 0, cashDeposit: 0 });
  assert.equal(etransferParts({ rental_cents: -5, rental_cash: false, deposit_cents: -1, deposit_method: 'e_transfer' }).total, 0);
});

test('the report says what the amount covers; the amount follows the choice', () => {
  const p = { rental: 50000, deposit: 60000 };
  assert.equal(coversFor(p, 'all'), 'both');
  assert.equal(coversFor(p, 'rental'), 'rental');
  assert.equal(coversFor(p, 'deposit'), 'deposit');
  assert.equal(coversFor({ rental: 50000, deposit: 0 }, 'all'), 'rental');
  assert.equal(coversFor({ rental: 0, deposit: 60000 }, 'all'), 'deposit');
  assert.equal(amountFor(p, 'all'), 110000);
  assert.equal(amountFor(p, 'rental'), 50000);
  assert.equal(amountFor(p, 'deposit'), 60000);
});

test('the staff message: the email, the booking number as the message, the exact amounts and the total', () => {
  const m = etransferMessage({ firstName: 'Nora', bookingNumber: 'CC-10700', email: 'pay@carmacars.ca', rentalCents: 50000, depositCents: 60000, fmt });
  assert.match(m, /^Hi Nora, card payments are paused/);
  assert.match(m, /Send to: pay@carmacars\.ca/);
  assert.match(m, /Message: CC-10700/);
  assert.match(m, /Rental: \$500\.00/);
  assert.match(m, /Refundable deposit: \$600\.00 \(given back by e-Transfer/);
  assert.match(m, /Total: \$1100\.00/);
  assert.match(m, /upload the e-Transfer screenshot/);
  const d = etransferMessage({ bookingNumber: 'CC-1', email: null, rentalCents: 0, depositCents: 60000, fmt });
  assert.match(d, /^Hi, /);
  assert.doesNotMatch(d, /Rental:|Total:/);
  assert.match(d, /our e-Transfer email/);
});

test('the database refuses every staff call that starts a card payment while paused, and Money carries the state', () => {
  for (const call of ['payreq_create', 'card_charge_begin', 'deposit_hold_saved_begin', 'hold_reauth_begin', 'extension_charge_begin']) assert.ok(SQL.includes(`'${call}'`), call);
  assert.match(SQL, /raise exception '%', app\.card_paused_message\(\)/);
  assert.match(SQL, /p_name = 'booking_money'[\s\S]*'card_payments', app\.card_payments_state\(\)/);
  assert.match(SQL, /and new\.deposit_pay_method = 'card' and app\.card_payments_on\(\)/);
  assert.match(SQL, /set search_path = public, app, pg_temp/);
});

test('the pages that took a card show e-Transfer while paused', () => {
  const checkout = read('../../app/account/bookings/[number]/checkout/page.tsx');
  assert.match(checkout, /cardOff && et \? \([\s\S]*<EtransferPay s=\{et\} \/>/);
  assert.match(checkout, /server_card_off_prepare/);
  assert.match(read('../../app/pay/[token]/page.tsx'), /paylink-card-off/);
  assert.match(read('../../server/actions/portal.ts'), /if \(!\(await cardPaymentsOn\(\)\)\) return fail\(CARD_OFF_RENTER, 'card_off'\)/);
  const money = read('./BookingMoney.tsx');
  assert.match(money, /const may = cardsOff \? \{ \.\.\.m\.may, collect: false, charge: false \} : m\.may;/);
  assert.match(money, /<CardPausedNote /);
  assert.doesNotMatch(money.slice(money.indexOf('const may = cardsOff')), /m\.may\./);
});
