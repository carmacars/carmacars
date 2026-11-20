// Checks the app's settings before a store build (npm run check; the build workflow runs it first). No device needed:
// it reads what `expo prebuild` will be given and the store listing, and fails on anything an App Store or Play review
// would send back.
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const APP = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const STORE = path.resolve(APP, '../carmacars/store');
const problems = [];
const ok = (cond, what) => { if (!cond) problems.push(what); };

const cfg = JSON.parse(execFileSync('npx', ['expo', 'config', '--json', '--type', 'public'], { cwd: APP, encoding: 'utf8', env: { ...process.env, EXPO_NO_TELEMETRY: '1' } }));
const ID = 'ca.carmacars.app';
ok(cfg.ios?.bundleIdentifier === ID && cfg.android?.package === ID, `the bundle id and the package are ${ID}`);
ok(/^\d+\.\d+\.\d+$/.test(cfg.version ?? ''), 'the version is major.minor.patch');
ok(cfg.scheme === 'carmacars', 'the carmacars:// scheme');
const domains = cfg.ios?.associatedDomains ?? [];
ok(domains.includes('applinks:carmacars.ca') && domains.includes('webcredentials:carmacars.ca'), 'universal links and passkeys: applinks and webcredentials for carmacars.ca');
const filters = cfg.android?.intentFilters ?? [];
ok(filters.some((f) => f.autoVerify && (f.data ?? []).some((d) => d.host === 'carmacars.ca' && d.scheme === 'https')), 'Android app links: a verified https filter for carmacars.ca');
ok(!filters.some((f) => (f.data ?? []).some((d) => (d.pathPrefix ?? '/') === '/' || String(d.pathPrefix).startsWith('/api'))), 'Android app links never take /api or every path');
const pm = cfg.ios?.privacyManifests;
ok(pm && pm.NSPrivacyTracking === false && Array.isArray(pm.NSPrivacyTrackingDomains) && pm.NSPrivacyTrackingDomains.length === 0, 'the privacy manifest says no tracking');
ok((pm?.NSPrivacyAccessedAPITypes ?? []).every((t) => (t.NSPrivacyAccessedAPITypeReasons ?? []).length > 0), 'every accessed API in the privacy manifest has a reason');
ok((pm?.NSPrivacyCollectedDataTypes ?? []).every((t) => t.NSPrivacyCollectedDataTypeTracking === false), 'no collected data is used for tracking');
const plist = cfg.ios?.infoPlist ?? {};
for (const k of ['NSCameraUsageDescription', 'NSPhotoLibraryUsageDescription', 'NSLocationWhenInUseUsageDescription', 'NSFaceIDUsageDescription']) ok(typeof plist[k] === 'string' && plist[k].length > 20, `${k} says why, in a sentence`);
ok(plist.ITSAppUsesNonExemptEncryption === false, 'the export compliance answer is set (no non-exempt encryption)');
const blocked = cfg.android?.blockedPermissions ?? [];
for (const p of ['android.permission.RECORD_AUDIO', 'android.permission.ACCESS_BACKGROUND_LOCATION']) ok(blocked.includes(p), `${p} is blocked`);
ok(!(cfg.android?.permissions ?? []).some((p) => /BACKGROUND_LOCATION|READ_CONTACTS|RECORD_AUDIO|READ_SMS/.test(p)), 'no permission the app does not use');
ok((cfg.extra?.apiUrl ?? '').startsWith('https://'), 'the API address is https');

// Apple guideline 5.1.1(v): an app with accounts deletes them from inside the app
ok(existsSync(path.join(APP, 'app/settings/delete-account.tsx')), 'the Delete my account screen exists');
ok(readFileSync(path.join(APP, 'app/(tabs)/profile.tsx'), 'utf8').includes('/settings/delete-account'), 'Profile links to Delete my account');
// every screen a link can open exists
const links = readFileSync(path.join(APP, 'src/logic/links.ts'), 'utf8');
for (const m of links.matchAll(/href: [`']\/([a-z]+(?:\/[a-z]+)?)/g)) {
  const first = m[1].split('/')[0];
  ok(['car', 'trip', 'field', 'sales', 'owner', 'trips', 'leads', 'profile', 'sign'].some((x) => first.startsWith(x)), `links.ts opens /${m[1]}, which has no screen`);
}

// the store listing, within each store's limits (apps/carmacars/store, shared with the first app)
const text = (f) => (existsSync(path.join(STORE, f)) ? readFileSync(path.join(STORE, f), 'utf8').trim() : null);
for (const [f, max] of [['ios/en-CA/name.txt', 30], ['ios/en-CA/subtitle.txt', 30], ['ios/en-CA/keywords.txt', 100], ['ios/en-CA/promotional_text.txt', 170], ['ios/en-CA/description.txt', 4000],
  ['android/en-CA/title.txt', 30], ['android/en-CA/short_description.txt', 80], ['android/en-CA/full_description.txt', 4000]]) {
  const t = text(f);
  ok(t !== null && t.length > 0 && t.length <= max, `${f}: present and at most ${max} characters${t ? ` (it has ${t.length})` : ''}`);
}
for (const f of ['android/play-icon-512.png', 'android/feature-graphic.png']) ok(existsSync(path.join(STORE, f)), `${f} exists`);
for (const f of ['assets/icon.png', 'assets/icon-foreground.png', 'assets/icon-background.png', 'assets/splash-mark.png', 'assets/notification/icon.png']) ok(existsSync(path.join(APP, f)), `${f} exists`);

if (problems.length) { console.error(`check-app: ${problems.length} problem(s)\n- ${problems.join('\n- ')}`); process.exit(1); }
console.log(`check-app: ok (${cfg.name} ${cfg.version}, ${ID}, Expo SDK ${cfg.sdkVersion})`);
