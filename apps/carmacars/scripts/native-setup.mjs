// Fits the native projects that `npx cap add ios` and `npx cap add android` make to CarmaCars (docs/apps/publish.md).
// The ios/ and android/ folders are not kept in the repository: the release workflow (.github/workflows/apps.yml) makes
// them fresh on each build, runs this, and builds. Running it twice changes nothing the second time.
//
//   node scripts/native-setup.mjs [ios|android|both]
//
// Reads, when set (never committed; the workflow writes them from GitHub secrets):
//   GOOGLE_SERVICES_JSON          path to Firebase's google-services.json (Android)
//   GOOGLE_SERVICE_INFO_PLIST     path to Firebase's GoogleService-Info.plist (iOS)
//   ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD   the upload key (Android)
//   APP_VERSION_NAME (1.0.0), APP_VERSION_CODE (a whole number that grows with every upload)
//
// iOS: the permission texts Apple shows (camera, photos, Face ID, location for signing and field photos), push alerts
// (remote-notification background mode, aps-environment), universal links and shared passwords (associated domains),
// export compliance (standard HTTPS only), the three AppDelegate hooks Firebase Messaging needs, and the Firebase file
// and entitlements added to the Xcode project (scripts/ios-project.rb, with the xcodeproj gem that macOS runners have).
// Android: verified app links for carmacars.ca, location for the WebView, the alert icon, colour and channel, the
// Firebase file, the release signing from the environment, and the version.
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP = join(dirname(fileURLToPath(import.meta.url)), '..');
const which = process.argv[2] ?? 'both';
const HOSTS = ['carmacars.ca', 'www.carmacars.ca'];
const log = (m) => console.log(`native-setup: ${m}`);
const read = (p) => readFileSync(p, 'utf8');
const write = (p, s) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, s); };

// ---------------------------------------------------------------- iOS
function plistSet(xml, key, valueXml) {
  const re = new RegExp(`\\s*<key>${key}</key>\\s*(<string>[^<]*</string>|<true/>|<false/>|<array>[\\s\\S]*?</array>|<dict>[\\s\\S]*?</dict>)`);
  const cleaned = xml.replace(re, '');
  return cleaned.replace(/<\/dict>\s*<\/plist>\s*$/, `\t<key>${key}</key>\n\t${valueXml}\n</dict>\n</plist>\n`);
}

function ios() {
  const dir = join(APP, 'ios', 'App', 'App');
  if (!existsSync(dir)) { log('no ios/ folder (run npx cap add ios first); skipped'); return; }
  const info = join(dir, 'Info.plist');
  let p = read(info);
  const str = (s) => `<string>${s}</string>`;
  for (const [k, v] of [
    ['CFBundleDisplayName', str('CarmaCars')],
    ['NSCameraUsageDescription', str('CarmaCars uses the camera for your driver\'s licence, your selfie and the photos of the car at pickup and return.')],
    ['NSPhotoLibraryUsageDescription', str('Choose a photo of your licence, proof of coverage or the car from your library.')],
    ['NSPhotoLibraryAddUsageDescription', str('CarmaCars saves a photo to your library only when you ask it to.')],
    ['NSFaceIDUsageDescription', str('Unlock CarmaCars with Face ID instead of signing in again.')],
    ['NSLocationWhenInUseUsageDescription', str('Your location is recorded with a signature and with pickup and return photos, as proof of where they happened.')],
    ['UIBackgroundModes', `<array>\n\t\t${str('remote-notification')}\n\t</array>`],
    ['ITSAppUsesNonExemptEncryption', '<false/>'],
    ['UIStatusBarStyle', str('UIStatusBarStyleLightContent')],
    ['UIViewControllerBasedStatusBarAppearance', '<true/>'],
    ['UIRequiredDeviceCapabilities', `<array>\n\t\t${str('arm64')}\n\t</array>`],
    ['UISupportedInterfaceOrientations', `<array>\n\t\t${str('UIInterfaceOrientationPortrait')}\n\t</array>`]
  ]) p = plistSet(p, k, v);
  write(info, p);
  log('Info.plist: name, permission texts, push background mode, export compliance, portrait');

  const ent = join(dir, 'App.entitlements');
  write(ent, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>aps-environment</key>
\t<string>production</string>
\t<key>com.apple.developer.usernotifications.time-sensitive</key>
\t<true/>
\t<key>com.apple.developer.associated-domains</key>
\t<array>
${HOSTS.map((h) => `\t\t<string>applinks:${h}</string>\n\t\t<string>webcredentials:${h}</string>`).join('\n')}
\t</array>
</dict>
</plist>
`);
  log('App.entitlements: push (production, urgent alerts time-sensitive), universal links and shared passwords for carmacars.ca');

  const del = join(dir, 'AppDelegate.swift');
  let d = read(del);
  if (!d.includes('capacitorDidRegisterForRemoteNotifications')) {
    const hooks = `
    // Firebase Messaging (@capacitor-firebase/messaging, docs/apps/publish.md): the APNs token and background alerts
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Notification.Name.init("didReceiveRemoteNotification"), object: completionHandler, userInfo: userInfo)
    }
`;
    const i = d.lastIndexOf('}');
    d = d.slice(0, i) + hooks + d.slice(i);
    write(del, d);
    log('AppDelegate.swift: the three Firebase Messaging hooks');
  }

  const gsi = process.env.GOOGLE_SERVICE_INFO_PLIST;
  if (gsi && existsSync(gsi)) { copyFileSync(gsi, join(dir, 'GoogleService-Info.plist')); log('GoogleService-Info.plist copied'); }
  else log('GoogleService-Info.plist not given: the app builds, alerts stay off');

  if (process.platform === 'darwin') {
    execFileSync('ruby', [join(APP, 'scripts', 'ios-project.rb'), join(APP, 'ios', 'App', 'App.xcodeproj')], { stdio: 'inherit' });
  } else log('not on macOS: the Xcode project is updated on the Mac build (scripts/ios-project.rb)');
}

// ---------------------------------------------------------------- Android
function android() {
  const root = join(APP, 'android', 'app');
  if (!existsSync(root)) { log('no android/ folder (run npx cap add android first); skipped'); return; }
  const man = join(root, 'src', 'main', 'AndroidManifest.xml');
  let m = read(man);
  if (!m.includes('android:autoVerify="true"')) {
    const filter = `
            <intent-filter android:autoVerify="true">
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="https" />
${HOSTS.map((h) => `                <data android:host="${h}" />`).join('\n')}
            </intent-filter>
`;
    m = m.replace(/(<category android:name="android\.intent\.category\.LAUNCHER" \/>\s*<\/intent-filter>\n)/, `$1${filter}`);
  }
  if (!m.includes('default_notification_icon')) {
    m = m.replace(/(\n\s*<\/application>)/, `
        <meta-data android:name="com.google.firebase.messaging.default_notification_icon" android:resource="@drawable/ic_stat_carmacars" />
        <meta-data android:name="com.google.firebase.messaging.default_notification_color" android:resource="@color/cc_red" />
        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id" android:value="alerts" />$1`);
  }
  for (const perm of ['android.permission.CAMERA', 'android.permission.ACCESS_COARSE_LOCATION', 'android.permission.ACCESS_FINE_LOCATION', 'android.permission.USE_BIOMETRIC']) {
    if (!m.includes(`"${perm}"`)) m = m.replace(/(\n\s*<uses-permission android:name="android\.permission\.INTERNET" \/>)/, `$1\n    <uses-permission android:name="${perm}" />`);
  }
  if (!m.includes('android.hardware.camera')) m = m.replace(/(\n<\/manifest>)/, `\n    <uses-feature android:name="android.hardware.camera" android:required="false" />$1`);
  write(man, m);
  log('AndroidManifest.xml: app links for carmacars.ca, camera, location, biometrics, alert icon, colour and channel');

  const colors = join(root, 'src', 'main', 'res', 'values', 'colors.xml');
  let c = existsSync(colors) ? read(colors) : '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n';
  if (!c.includes('cc_red')) c = c.replace('</resources>', '    <color name="cc_red">#D0111B</color>\n</resources>');
  write(colors, c);
  const icons = join(APP, 'assets', 'notification');
  for (const d of readdirSync(icons)) {
    const to = join(root, 'src', 'main', 'res', d);
    mkdirSync(to, { recursive: true });
    copyFileSync(join(icons, d, 'ic_stat_carmacars.png'), join(to, 'ic_stat_carmacars.png'));
  }
  log('alert icon (white silhouette) and the CarmaCars red');

  const gs = process.env.GOOGLE_SERVICES_JSON;
  if (gs && existsSync(gs)) { copyFileSync(gs, join(root, 'google-services.json')); log('google-services.json copied'); }
  else log('google-services.json not given: the app builds, alerts stay off');

  const gradle = join(root, 'build.gradle');
  let g = read(gradle);
  const name = process.env.APP_VERSION_NAME, code = process.env.APP_VERSION_CODE;
  if (name && /^\d+\.\d+\.\d+$/.test(name)) g = g.replace(/versionName "[^"]*"/, `versionName "${name}"`);
  if (code && /^\d+$/.test(code)) g = g.replace(/versionCode \d+/, `versionCode ${code}`);
  if (process.env.ANDROID_KEYSTORE_PATH && !g.includes('signingConfigs')) {
    g = g.replace(/android \{\n/, `android {
    // the upload key, from the release workflow's secrets (never committed); Google re-signs with the app signing key
    signingConfigs {
        release {
            storeFile file(System.getenv("ANDROID_KEYSTORE_PATH"))
            storePassword System.getenv("ANDROID_KEYSTORE_PASSWORD")
            keyAlias System.getenv("ANDROID_KEY_ALIAS")
            keyPassword System.getenv("ANDROID_KEY_PASSWORD")
        }
    }
`);
    g = g.replace(/(buildTypes \{\s*release \{\n)/, '$1            signingConfig signingConfigs.release\n');
  }
  write(gradle, g);
  log(`build.gradle: version ${name ?? '(template)'} (${code ?? 'template'})${process.env.ANDROID_KEYSTORE_PATH ? ', release signing from the environment' : ''}`);
}

if (which === 'ios' || which === 'both') ios();
if (which === 'android' || which === 'both') android();
