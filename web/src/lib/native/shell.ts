// The App Store and Google Play app (migration 0390, apps/carmacars): a Capacitor shell that opens this site. The shell
// adds a token to the WebView's user agent (apps/carmacars/capacitor.config.ts, appendUserAgent), so the site can tell
// the app from a browser on the server (dynamic pages: the alerts card) and before the first paint (the inline script
// in the root layout sets <html data-shell="app">, which hides the web-only parts). No imports: shared by the server,
// the client, the Worker and the unit tests.

/** The user agent token, "CarmaCarsApp/<shell version> <platform>". Keep in step with apps/carmacars/capacitor.config.ts. */
export const APP_UA = 'CarmaCarsApp/';
/** The store app's bundle and package id (App Store, Google Play, Firebase, the app links files). */
export const APP_ID = 'ca.carmacars.app';

export type AppPlatform = 'ios' | 'android';
export interface AppShell { version: number; platform: AppPlatform }

/** The app shell this user agent is, or null for a browser. */
export function appShellOf(ua: string | null | undefined): AppShell | null {
  const m = /CarmaCarsApp\/(\d{1,3}) (ios|android)\b/.exec(ua ?? '');
  return m ? { version: Number(m[1]), platform: m[2] as AppPlatform } : null;
}

export function isAppShell(ua: string | null | undefined): boolean {
  return appShellOf(ua) !== null;
}

/** The inline script of the root layout: marks <html> before the first paint, so web-only parts never flash. */
export const SHELL_MARK_SCRIPT = `try{var m=/CarmaCarsApp\\/\\d{1,3} (ios|android)\\b/.exec(navigator.userAgent);if(m){var d=document.documentElement;d.setAttribute('data-shell','app');d.setAttribute('data-platform',m[1])}}catch(e){}`;

/**
 * Where a link that opened the app should go inside it: a path of this site (universal links, app links, a tapped
 * alert's page), or null for anything else (another site, a script URL). Accepts the site's own addresses (with or
 * without www), the app's start address and a bare path.
 */
export function appPathOf(raw: string | null | undefined, hosts: readonly string[] = ['carmacars.ca', 'www.carmacars.ca']): string | null {
  const s = (raw ?? '').trim();
  if (!s) return null;
  if (s.startsWith('/') && !s.startsWith('//') && !s.startsWith('/\\')) return safePath(s);
  let u: URL;
  try { u = new URL(s); } catch { return null; }
  if (u.protocol !== 'https:' || !hosts.includes(u.hostname.toLowerCase()) || u.username || u.password) return null;
  return safePath(u.pathname + u.search + u.hash);
}

function safePath(p: string): string | null {
  // control characters and backslashes never: a path only
  return /^\/[^\\\s]*$/.test(p) && !/[\u0000-\u001f]/.test(p) ? p : null;
}

/** The universal links (iOS) and app links (Android) files. Null: the store ids are not set yet (the files answer 404). */
export function appleAppSiteAssociation(teamId: string | null | undefined): Record<string, unknown> | null {
  const team = (teamId ?? '').trim().toUpperCase();
  if (!/^[A-Z0-9]{10}$/.test(team)) return null;
  const app = `${team}.${APP_ID}`;
  return {
    applinks: {
      details: [{
        appIDs: [app],
        // every page opens in the app, except files and feeds that are not pages
        components: [
          { '/': '/api/*', exclude: true, comment: 'the site\'s programs' },
          { '/': '/files/*', exclude: true }, { '/': '/guide-pdf/*', exclude: true },
          { '/': '/partner-feed/*', exclude: true }, { '/': '/partner-widget/*', exclude: true },
          { '/': '/sitemap*', exclude: true }, { '/': '/llms*', exclude: true }, { '/': '/.well-known/*', exclude: true },
          { '/': '/*' }
        ]
      }]
    },
    // passwords saved for carmacars.ca fill in the app's sign-in
    webcredentials: { apps: [app] }
  };
}

export function androidAssetLinks(fingerprints: string | null | undefined): unknown[] | null {
  const prints = (fingerprints ?? '').split(/[\s,]+/).map((f) => f.trim().toUpperCase()).filter((f) => /^([0-9A-F]{2}:){31}[0-9A-F]{2}$/.test(f));
  if (!prints.length) return null;
  return [{
    relation: ['delegate_permission/common.handle_all_urls', 'delegate_permission/common.get_login_creds'],
    target: { namespace: 'android_app', package_name: APP_ID, sha256_cert_fingerprints: [...new Set(prints)] }
  }];
}
