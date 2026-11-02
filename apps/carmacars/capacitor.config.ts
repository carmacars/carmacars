import type { CapacitorConfig } from '@capacitor/cli';

// The CarmaCars app for the App Store and Google Play (docs/decisions/0002-native-apps-plan.md, docs/apps/publish.md).
// One app for every role: it opens carmacars.ca/app, which sends a signed-in person to their portal (renter, owner,
// investor, staff, field, admin) and anyone else to the home page. The site itself is the app's screens, so every
// release of the site reaches the app at once; only native changes need a store update.
//
// What the shell adds (Apple guideline 4.2, minimum functionality): push alerts through Firebase Cloud Messaging
// (APNs on iPhone), the native camera for licence and condition photos, Face ID and fingerprint unlock, deep links from
// emails and texts (universal links and app links), the share sheet, haptics, a black status bar and splash screen,
// and an offline screen bundled in the app (www/offline.html). The site finds the shell by the user agent below
// (web/src/lib/native/shell.ts) and talks to the plugins through @capacitor/core (web/src/lib/native/bridge.ts).
//
// No import other than the type: scripts/check-app.mjs reads this file with Node's type stripping, without installing.

const SITE = 'https://carmacars.ca';

/** The user agent token the site detects the app by. Keep in step with web/src/lib/native/shell.ts (APP_UA). */
export const APP_UA = 'CarmaCarsApp/1';

const config: CapacitorConfig = {
  appId: 'ca.carmacars.app',
  appName: 'CarmaCars',
  webDir: 'www',
  backgroundColor: '#000000',
  loggingBehavior: 'debug',
  server: {
    // the live site; /app routes to the right portal
    url: `${SITE}/app`,
    // pages the app keeps inside itself: the site and Stripe's payment pages (card checks, 3-D Secure). Every other
    // link (Google Maps, the guides' PDFs on other hosts, social pages) opens in the phone's browser.
    allowNavigation: ['carmacars.ca', 'www.carmacars.ca', '*.stripe.com', '*.stripe.network', 'challenges.cloudflare.com'],
    // no connection, or the site did not answer: the bundled screen with Try again
    errorPath: 'offline.html',
    cleartext: false,
    androidScheme: 'https'
  },
  ios: {
    appendUserAgent: `${APP_UA} ios`,
    contentInset: 'automatic',
    backgroundColor: '#000000',
    // the web inspector only in debug builds
    webContentsDebuggingEnabled: false,
    // universal links and push alerts are handled by Capacitor's AppDelegate proxy (scripts/native-setup.mjs)
    handleApplicationNotifications: true
  },
  android: {
    appendUserAgent: `${APP_UA} android`,
    backgroundColor: '#000000',
    allowMixedContent: false,
    webContentsDebuggingEnabled: false,
    captureInput: true
  },
  plugins: {
    SplashScreen: {
      // hidden by the site once the first page has painted (web/src/features/app-shell/AppShell.tsx), at most 4 s
      launchShowDuration: 4000,
      launchAutoHide: true,
      launchFadeOutDuration: 200,
      backgroundColor: '#000000',
      showSpinner: false,
      androidScaleType: 'CENTER_CROP',
      splashFullScreen: false,
      splashImmersive: false
    },
    StatusBar: {
      // light text and icons on the black header
      style: 'DARK',
      backgroundColor: '#000000',
      overlaysWebView: false
    },
    SystemBars: {
      insetsHandling: 'css',
      style: 'DARK'
    },
    FirebaseMessaging: {
      // an alert that arrives while the app is open still shows as a banner, with its sound
      presentationOptions: ['alert', 'badge', 'sound']
    },
    CapacitorHttp: { enabled: false },
    CapacitorCookies: { enabled: false }
  },
  experimental: {
    ios: {
      spm: {
        // @capacitor-firebase/messaging's Swift package identity (its README, Capacitor CLI 8.4 and later)
        packageOptions: { '@capacitor-firebase/messaging': { symlink: true } }
      }
    }
  }
};

export default config;
