// Referral partners and the RentalCoverage link (migration 0164): the codes, the rate words, the private-page key and the
// affiliate destination. npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { affiliateDestination, asPlacement, cleanCode, coverageGo, isCode, portalKey, portalKeyOk, rateWords, referralLink, typedReferralCode } from './model.ts';

test('codes: cleaned, checked, and read from what a visitor typed', () => {
  assert.equal(cleanCode(' ab-12 cd '), 'AB12CD');
  assert.ok(isCode('AB12CD'));
  assert.ok(!isCode('ab12cd'));
  assert.ok(!isCode('AB1'));
  assert.equal(typedReferralCode(' bodyshop7 '), 'BODYSHOP7');
  assert.equal(typedReferralCode('Maria Lopez'), null);
  assert.equal(typedReferralCode('abc'), null);
  assert.equal(referralLink('https://carmacars.ca/', 'AB12CD'), 'https://carmacars.ca/r/AB12CD');
});

test('the rate in words: a flat amount or a percentage', () => {
  assert.equal(rateWords('flat', 5000, 1000), '$50 per completed rental');
  assert.equal(rateWords('flat', 4550, 1000), '$45.50 per completed rental');
  assert.equal(rateWords('percent', 5000, 1250), '12.5% of the rental charge');
});

test('the private page key: it opens for its partner and version only', async () => {
  const k = await portalKey('secret', 'p1', 1);
  assert.ok(await portalKeyOk('secret', 'p1', 1, k));
  assert.ok(!(await portalKeyOk('secret', 'p1', 2, k)), 'a new link ends the old one');
  assert.ok(!(await portalKeyOk('secret', 'p2', 1, k)));
  assert.ok(!(await portalKeyOk('other', 'p1', 1, k)));
  assert.ok(!(await portalKeyOk('secret', 'p1', 1, null)));
  assert.notEqual(k, await portalKey('secret', 'p1', 2));
});

test('the affiliate link: https only, the ID filled in, UTM added, its own parameters kept', () => {
  const u = new URL(affiliateDestination('https://x.example/?aff={id}&keep=1', 'a b', 'requirements')!);
  assert.equal(u.searchParams.get('aff'), 'a b');
  assert.equal(u.searchParams.get('keep'), '1');
  assert.equal(u.searchParams.get('utm_source'), 'carmacars');
  assert.equal(u.searchParams.get('utm_medium'), 'referral');
  assert.equal(u.searchParams.get('utm_campaign'), 'coverage_requirements');
  assert.equal(affiliateDestination('http://x.example/', null, 'other'), null);
  assert.equal(affiliateDestination('https://x.example/?aff={id}', '  ', 'other'), null);
  assert.equal(affiliateDestination(null, null, 'other'), null);
  const own = new URL(affiliateDestination('https://x.example/?utm_source=theirs', null, 'card_guide')!);
  assert.equal(own.searchParams.get('utm_source'), 'theirs');
});

test('the site link carries the place and the booking', () => {
  assert.equal(asPlacement('nope'), 'other');
  assert.equal(coverageGo('booking_step'), '/go/coverage?p=booking_step');
  assert.equal(coverageGo('booking_page', 'CC-1 2'), '/go/coverage?p=booking_page&b=CC-1%202');
});
