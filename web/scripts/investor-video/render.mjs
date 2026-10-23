// The investor video, step 4: the pictures (docs/investor-video/script.md).
//   node scripts/investor-video/render.mjs --dir <out> [--workers 3]            every frame, 1920x1080 at 30 fps, to <out>/video.mp4 (no sound)
//   node scripts/investor-video/render.mjs --dir <out> --sheet 12 [--scale 0.25] that many stills across the video, to <out>/sheet/NN.png
// Serves the stage (stage.html from build.mjs, with the deck's fonts, styles and screens) to Chromium, sets each frame
// with the stage's clock (stage.js window.__seek) and screenshots it. The same frame number always gives the same picture.
import { chromium } from '@playwright/test';
import { spawn } from 'node:child_process';
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = resolve(HERE, '../..');
const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const dir = resolve(arg('dir', join(WEB, '.video')));
const timeline = JSON.parse(readFileSync(join(dir, 'timeline.json'), 'utf8'));
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.jpg': 'image/jpeg', '.png': 'image/png', '.svg': 'image/svg+xml' };
const ALLOWED = ['/src/fonts/', '/public/deck/', '/scripts/investor-video/', '/public/'];

const server = createServer((req, res) => {
  const p = normalize(decodeURIComponent((req.url || '/').split('?')[0]));
  const file = p === '/' ? join(dir, 'stage.html') : ALLOWED.some((a) => p.startsWith(a)) ? join(WEB, p) : null;
  if (!file || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' });
  createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}/`;
const browser = await chromium.launch({ args: ['--no-proxy-server', '--font-render-hinting=none', '--disable-lcd-text', '--hide-scrollbars'] });

async function open(scale = 1) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: scale });
  page.on('pageerror', (e) => { console.error('stage error:', e.message); process.exitCode = 1; });
  await page.goto(base, { waitUntil: 'load' });
  const n = await page.evaluate((tl) => window.__init(tl), timeline);
  await page.evaluate(() => window.__ready());
  return { page, n };
}

const run = (cmd, args, opts = {}) => spawn(cmd, args, { stdio: ['pipe', 'inherit', 'inherit'], ...opts });
const done = (p) => new Promise((ok, no) => p.on('close', (c) => (c === 0 ? ok() : no(new Error(`${p.spawnargs[0]} exited ${c}`)))));

if (arg('sheet')) {
  // stills for a contact sheet (a quick look at the layout, before any voice exists)
  const count = Number(arg('sheet'));
  const scale = Number(arg('scale', '0.25'));
  mkdirSync(join(dir, 'sheet'), { recursive: true });
  const { page } = await open(scale);
  const times = arg('times') ? arg('times').split(',').map(Number) : Array.from({ length: count }, (_, k) => timeline.total * (k + 0.5) / count);
  for (const [k, t] of times.entries()) {
    await page.evaluate((x) => window.__seek(x), t);
    await page.screenshot({ path: join(dir, 'sheet', `${String(k + 1).padStart(2, '0')}.png`) });
  }
  writeFileSync(join(dir, 'sheet', 'times.json'), JSON.stringify(times));
  console.log(`sheet: ${times.length} stills in ${join(dir, 'sheet')}`);
} else {
  const workers = Math.max(1, Number(arg('workers', '3')));
  const frames = timeline.frames;
  const per = Math.ceil(frames / workers);
  mkdirSync(join(dir, 'seg'), { recursive: true });
  const started = Date.now();
  let made = 0;
  await Promise.all(Array.from({ length: workers }, async (_, w) => {
    const from = w * per, to = Math.min(frames, from + per);
    if (from >= to) return;
    const { page } = await open(1);
    const enc = run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', String(timeline.fps), '-c:v', 'mjpeg', '-i', '-',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '17', '-maxrate', '9M', '-bufsize', '18M', '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-g', String(timeline.fps * 2),
      '-r', String(timeline.fps), join(dir, 'seg', `${String(w).padStart(2, '0')}.mp4`)]);
    for (let f = from; f < to; f++) {
      await page.evaluate((x) => window.__seek(x), f / timeline.fps);
      const jpg = await page.screenshot({ type: 'jpeg', quality: 93 });
      if (!enc.stdin.write(jpg)) await new Promise((r) => enc.stdin.once('drain', r));
      if (++made % 300 === 0) console.log(`render: ${made}/${frames} frames, ${((Date.now() - started) / 1000).toFixed(0)} s`);
    }
    enc.stdin.end();
    await done(enc);
    await page.close();
  }));
  const list = join(dir, 'seg', 'list.txt');
  writeFileSync(list, Array.from({ length: workers }, (_, w) => join(dir, 'seg', `${String(w).padStart(2, '0')}.mp4`)).filter(existsSync).map((f) => `file '${f}'`).join('\n'));
  await done(run('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', join(dir, 'video.mp4')]));
  console.log(`render: ${frames} frames in ${((Date.now() - started) / 1000).toFixed(0)} s -> ${join(dir, 'video.mp4')}`);
}
await browser.close();
server.close();
