import { test } from 'node:test';
import assert from 'node:assert/strict';
import { androidAssetLinks, appPathOf, appShellOf, appleAppSiteAssociation, isAppShell, APP_ID, SHELL_MARK_SCRIPT } from './shell.ts';
import { readFileSync } from 'node:fs';

// The store app (migration 0390): the site tells the app from a browser by the user agent token the shell adds, takes a
// link that opened the app only when it is a page of this site, and serves the universal links and app links files once
// the store ids are set. The ids here are placeholders, not CarmaCars' real ones.
const IOS = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 CarmaCarsApp/1 ios';
const ANDROID = 'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/141.0 Mobile Safari/537.36 CarmaCarsApp/1 android';

test('the app shell by its user agent token; browsers are not', () => {
  assert.deepEqual(appShellOf(IOS), { version: 1, platform: 'ios' });
  assert.deepEqual(appShellOf(ANDROID), { version: 1, platform: 'android' });
  for (const ua of ['Mozilla/5.0 (iPhone) Safari/605.1', 'CarmaCarsApp/x ios', 'CarmaCarsApp/1 windows', '', null, undefined]) assert.equal(isAppShell(ua), false, String(ua));
});

test('the root layout script marks <html> in the app only', () => {
  const run = (ua: string) => {
    const attrs: Record<string, string> = {};
    new Function('navigator', 'document', SHELL_MARK_SCRIPT)({ userAgent: ua }, { documentElement: { setAttribute: (k: string, v: string) => { attrs[k] = v; } } });
    return attrs;
  };
  assert.deepEqual(run(IOS), { 'data-shell': 'app', 'data-platform': 'ios' });
  assert.deepEqual(run(ANDROID), { 'data-shell': 'app', 'data-platform': 'android' });
  assert.deepEqual(run('Mozilla/5.0 Chrome/141'), {});
});

test('a link that opened the app: pages of this site only', () => {
  assert.equal(appPathOf('https://carmacars.ca/account/bookings/CC-10001?x=1#pay'), '/account/bookings/CC-10001?x=1#pay');
  assert.equal(appPathOf('https://www.carmacars.ca/auth/callback?token_hash=abc&type=magiclink'), '/auth/callback?token_hash=abc&type=magiclink');
  assert.equal(appPathOf('/staff/field'), '/staff/field');
  for (const bad of ['https://evil.example.test/account', 'http://carmacars.ca/account', 'javascript:alert(1)', '//evil.example.test/x', '/\\evil', 'https://user:pw@carmacars.ca/', '', null, 'not a url'])
    assert.equal(appPathOf(bad), null, String(bad));
});

test('universal links: only with a Team ID; every page but files and feeds; shared passwords', () => {
  assert.equal(appleAppSiteAssociation(undefined), null);
  assert.equal(appleAppSiteAssociation('short'), null);
  const a = appleAppSiteAssociation('abcde12345') as { applinks: { details: Array<{ appIDs: string[]; components: Array<Record<string, unknown>> }> }; webcredentials: { apps: string[] } };
  assert.deepEqual(a.applinks.details[0]!.appIDs, [`ABCDE12345.${APP_ID}`]);
  assert.deepEqual(a.webcredentials.apps, [`ABCDE12345.${APP_ID}`]);
  const c = a.applinks.details[0]!.components;
  assert.deepEqual(c.at(-1), { '/': '/*' }, 'everything else opens in the app');
  assert.ok(c.some((x) => x['/'] === '/api/*' && x.exclude === true));
});

test('app links: only with well-formed fingerprints, deduplicated', () => {
  const fp = Array.from({ length: 32 }, (_, i) => (i * 7 % 256).toString(16).padStart(2, '0')).join(':');
  assert.equal(androidAssetLinks(''), null);
  assert.equal(androidAssetLinks('AB:CD'), null);
  const l = androidAssetLinks(`${fp}, ${fp.toUpperCase()}`) as Array<{ target: { package_name: string; sha256_cert_fingerprints: string[] } }>;
  assert.equal(l[0]!.target.package_name, APP_ID);
  assert.deepEqual(l[0]!.target.sha256_cert_fingerprints, [fp.toUpperCase()]);
});

test('the site and the app agree on the user agent token and the app id', () => {
  const cfg = readFileSync(new URL('../../../../apps/carmacars/capacitor.config.ts', import.meta.url), 'utf8');
  assert.match(cfg, /export const APP_UA = 'CarmaCarsApp\/1';/);
  assert.match(cfg, new RegExp(`appId: '${APP_ID.replace(/\./g, '\\.')}'`));
  assert.ok(appShellOf(`x CarmaCarsApp/1 ios`) && /appendUserAgent: `\$\{APP_UA\} ios`/.test(cfg) && /appendUserAgent: `\$\{APP_UA\} android`/.test(cfg));
});
