// The store app's cheap check (CI, every push; no install, about a second): the Capacitor config, the bundled offline
// screen, the icon and splash files, the store listing text against the stores' limits, and that no key or Firebase
// file was committed.
//
//   node scripts/check-app.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP = join(dirname(fileURLToPath(import.meta.url)), '..');
const problems = [];
const bad = (m) => problems.push(m);

// ---- the config (read with Node's type stripping: the file imports only a type)
const cfg = JSON.parse(execFileSync(process.execPath, ['--experimental-strip-types', '--no-warnings', '--input-type=module', '-e',
  `const m = await import(${JSON.stringify(join(APP, 'capacitor.config.ts'))}); console.log(JSON.stringify({ ...m.default, APP_UA: m.APP_UA }));`], { encoding: 'utf8' }));
if (cfg.appId !== 'ca.carmacars.app') bad(`appId is ${cfg.appId}, not ca.carmacars.app`);
if (cfg.appName !== 'CarmaCars') bad('appName is not CarmaCars');
if (!/^https:\/\/carmacars\.ca\//.test(cfg.server?.url ?? '')) bad('server.url must be the live site over https');
if (cfg.server?.cleartext !== false) bad('server.cleartext must be false');
if (!existsSync(join(APP, cfg.webDir, 'index.html'))) bad(`${cfg.webDir}/index.html is missing`);
if (!cfg.server?.errorPath || !existsSync(join(APP, cfg.webDir, cfg.server.errorPath))) bad('server.errorPath must be a file in webDir (the offline screen)');
for (const p of ['ios', 'android']) {
  if (cfg[p]?.appendUserAgent !== `${cfg.APP_UA} ${p}`) bad(`${p}.appendUserAgent must be "${cfg.APP_UA} ${p}" (web/src/lib/native/shell.ts reads it)`);
  if (cfg[p]?.webContentsDebuggingEnabled !== false) bad(`${p}.webContentsDebuggingEnabled must be false in release`);
}
const offline = readFileSync(join(APP, cfg.webDir, cfg.server.errorPath), 'utf8');
if (/https?:\/\/(?!carmacars\.ca)[a-z0-9.-]+\//i.test(offline.replace(/<!doctype[^>]*>/i, ''))) bad('the offline screen must not load anything from another site');

// ---- the plugins the site calls (web/src/lib/native/bridge.ts and its users) are in the app
const pkg = JSON.parse(readFileSync(join(APP, 'package.json'), 'utf8'));
const PLUGINS = { App: '@capacitor/app', Camera: '@capacitor/camera', Haptics: '@capacitor/haptics', Network: '@capacitor/network', Preferences: '@capacitor/preferences',
  Share: '@capacitor/share', SplashScreen: '@capacitor/splash-screen', StatusBar: '@capacitor/status-bar', FirebaseMessaging: '@capacitor-firebase/messaging',
  BiometricAuthNative: '@aparajita/capacitor-biometric-auth' };
const webSrc = join(APP, '..', '..', 'web', 'src');
const used = new Set();
// the files that use the bridge: every call('Plugin', ...), listen('Plugin', ...) and has('Plugin'), and the plugin names
// kept in constants (const FCM = 'FirebaseMessaging')
const walk = (d) => {
  for (const f of readdirSync(d)) {
    const p = join(d, f);
    if (statSync(p).isDirectory()) { walk(p); continue; }
    if (!/\.tsx?$/.test(f) || /\.test\.tsx?$/.test(f)) continue;
    const src = readFileSync(p, 'utf8');
    if (!/from '@\/lib\/native\/bridge'/.test(src) && !p.endsWith(join('lib', 'native', 'bridge.ts'))) continue;
    const consts = Object.fromEntries([...src.matchAll(/const ([A-Z]+) = '([A-Za-z]+)';/g)].map((m) => [m[1], m[2]]));
    for (const m of src.matchAll(/\b(?:call|listen|has)(?:<[^>]*>)?\(\s*(?:'([A-Za-z]+)'|([A-Z]+)\b)/g)) {
      const name = m[1] ?? consts[m[2]];
      if (name) used.add(name);
    }
  }
};
if (existsSync(webSrc)) walk(webSrc);
for (const name of used) {
  if (!PLUGINS[name]) bad(`the site calls the plugin ${name}, which this check does not know: add it to PLUGINS and to package.json`);
  else if (!pkg.dependencies?.[PLUGINS[name]]) bad(`the site calls ${name}: ${PLUGINS[name]} must be in package.json`);
}

// ---- icons and splash (PNG headers: width, height, colour type)
function png(rel) {
  const p = join(APP, rel);
  if (!existsSync(p)) { bad(`${rel} is missing (node scripts/gen-assets.mjs)`); return null; }
  const b = readFileSync(p);
  if (b.readUInt32BE(0) !== 0x89504e47) { bad(`${rel} is not a PNG`); return null; }
  return { w: b.readUInt32BE(16), h: b.readUInt32BE(20), alpha: [4, 6].includes(b[25]) };
}
const want = (rel, w, h, opts = {}) => {
  const i = png(rel);
  if (!i) return;
  if (i.w !== w || i.h !== h) bad(`${rel} is ${i.w}x${i.h}, not ${w}x${h}`);
  if (opts.opaque && i.alpha) bad(`${rel} must have no transparency (Apple refuses an icon with an alpha channel)`);
};
want('assets/icon-only.png', 1024, 1024, { opaque: true });
want('assets/icon-foreground.png', 1024, 1024);
want('assets/icon-background.png', 1024, 1024);
want('assets/splash.png', 2732, 2732);
want('assets/splash-dark.png', 2732, 2732);
for (const [d, px] of [['mdpi', 24], ['hdpi', 36], ['xhdpi', 48], ['xxhdpi', 72], ['xxxhdpi', 96]]) want(`assets/notification/drawable-${d}/ic_stat_carmacars.png`, px, px);
want('store/android/play-icon-512.png', 512, 512, { opaque: true });
want('store/android/feature-graphic.png', 1024, 500, { opaque: true });

// ---- the store listing text (fastlane's layout: store/ios/<locale>/*.txt, store/android/<locale>/*.txt)
const LIMITS = {
  ios: { 'name.txt': 30, 'subtitle.txt': 30, 'keywords.txt': 100, 'promotional_text.txt': 170, 'description.txt': 4000, 'release_notes.txt': 4000,
    'privacy_url.txt': 255, 'support_url.txt': 255, 'marketing_url.txt': 255 },
  android: { 'title.txt': 30, 'short_description.txt': 80, 'full_description.txt': 4000, 'changelogs/1.txt': 500 }
};
for (const [store, files] of Object.entries(LIMITS)) {
  const base = join(APP, 'store', store);
  for (const loc of existsSync(base) ? readdirSync(base).filter((x) => /^[a-z]{2}-[A-Z]{2}$/.test(x)) : []) {
    for (const [f, max] of Object.entries(files)) {
      const p = join(base, loc, f), rel = relative(APP, p);
      if (!existsSync(p)) { bad(`${rel} is missing`); continue; }
      const t = readFileSync(p, 'utf8').trim();
      const n = [...t].length;
      if (!n) bad(`${rel} is empty`);
      if (n > max) bad(`${rel} has ${n} characters; the store allows ${max}`);
      if (/[—]| – /.test(t)) bad(`${rel} has an em dash or a spaced en dash`);
      if (f.endsWith('_url.txt') && !/^https:\/\/carmacars\.ca(\/[\w/-]*)?$/.test(t)) bad(`${rel} must be a carmacars.ca https address`);
      if (f === 'keywords.txt' && /,\s/.test(t)) bad(`${rel}: no space after a comma (each one counts toward the 100)`);
    }
  }
  if (!existsSync(base)) bad(`store/${store} is missing`);
}

// ---- nothing secret in the app folder
const SECRET = /^(google-services\.json|GoogleService-Info\.plist|.*\.(jks|keystore|p8|p12|mobileprovision|pem))$/i;
const scan = (d) => { for (const f of readdirSync(d)) { if (f === 'node_modules' || f === 'ios' || f === 'android') continue; const p = join(d, f); if (statSync(p).isDirectory()) scan(p); else if (SECRET.test(f)) bad(`${relative(APP, p)} must never be committed (a key or a Firebase file: GitHub secrets only)`); } };
scan(APP);

if (problems.length) { for (const p of problems) console.error(`check-app: ${p}`); process.exit(1); }
console.log(`check-app: config, offline screen, ${used.size} plugins the site calls, icons, splash and store text are in order`);
