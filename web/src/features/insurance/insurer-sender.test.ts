import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// R51 (REQ-137, the owner Nov 27: "DO NOT SEND IT FROM RENT@CARMACARS.CA"): no insurer email names rent@carmacars.ca as its
// sender, reply-to or anywhere in its template, and the sender is the Blind Spot address. The database refuses it too (5204).
const ROOT = join(import.meta.dirname, '../../../..');
const cat = JSON.parse(readFileSync(join(ROOT, 'emails', 'catalogue.json'), 'utf8')) as { emails: Array<{ code: string; audience: string; also_sent_to?: string[]; from?: string; reply_to?: string }> };
const insurer = cat.emails.filter((e) => e.audience === 'insurer' || (e.also_sent_to ?? []).includes('insurer'));
const RENT = /rent@carmacars\.ca/i;

test('every insurer email: from and reply-to the Blind Spot address, never rent@', () => {
  assert.ok(insurer.length >= 3, 'the insurer emails are in the catalogue');
  for (const e of insurer) {
    assert.match(e.from ?? '', /<blindspotcarrental@carmacars\.ca>$/, `${e.code} from`);
    assert.doesNotMatch(`${e.from ?? ''} ${e.reply_to ?? ''}`, RENT, e.code);
  }
});

test('no insurer email template names rent@', () => {
  const dir = join(ROOT, 'emails', 'templates');
  const files = readdirSync(dir).filter((f) => insurer.some((e) => f === `${e.code}.html` || f === `${e.code}.txt`));
  assert.ok(files.length >= insurer.length, 'the templates are there');
  for (const f of files) assert.doesNotMatch(readFileSync(join(dir, f), 'utf8'), RENT, f);
});

test('the sender function never sets rent@ for any email', () => {
  assert.doesNotMatch(readFileSync(join(ROOT, 'supabase', 'functions', 'send-outbox', 'index.ts'), 'utf8'), RENT);
});
