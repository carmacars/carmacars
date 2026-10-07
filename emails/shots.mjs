#!/usr/bin/env node
// Screenshots of every rendered email: desktop (640 wide) and phone (375 wide).
//
//   PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers node emails/shots.mjs [code ...] [--dark]
//
// Uses the globally installed Playwright. With codes, only those emails are shot. --dark adds a dark-mode pair.
import { readdirSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require('playwright')); } catch { ({ chromium } = require('/opt/node22/lib/node_modules/playwright')); }

const ROOT = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const dark = args.includes('--dark');
const only = args.filter((a) => !a.startsWith('--'));
const codes = readdirSync(join(ROOT, 'dist')).filter((f) => f.endsWith('.html')).map((f) => f.slice(0, -5))
  .filter((c) => !only.length || only.includes(c));
mkdirSync(join(ROOT, 'shots'), { recursive: true });

const browser = await chromium.launch();
const sizes = [['desktop', 640], ['phone', 375]];
for (const scheme of dark ? ['light', 'dark'] : ['light']) {
  for (const [name, width] of sizes) {
    const ctx = await browser.newContext({ viewport: { width, height: 800 }, colorScheme: scheme, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    for (const code of codes) {
      await page.goto(pathToFileURL(join(ROOT, 'dist', code + '.html')).href);
      await page.screenshot({ path: join(ROOT, 'shots', `${code}.${name}${scheme === 'dark' ? '.dark' : ''}.png`), fullPage: true });
    }
    await ctx.close();
  }
}
await browser.close();
console.log(`Shot ${codes.length} emails at ${sizes.map((s) => s[1]).join(' and ')} wide${dark ? ', light and dark' : ''}.`);
