import { targetFor } from '@/logic/links';

// A link that opens the app from outside (a universal link or app link to carmacars.ca, carmacars://, a tapped alert
// when the app was closed) arrives here before any screen shows. The site's address becomes the app's own screen when it
// has one (src/logic/links.ts); any other page of the site goes to the screen that opens it in the in-app browser; a
// link that is not the site's opens the app at its start.
export function redirectSystemPath({ path }: { path: string; initial: boolean }): string {
  try {
    const t = targetFor(path);
    if (t?.kind === 'screen') return t.href;
    if (t?.kind === 'web') return `/web?path=${encodeURIComponent(t.path)}`;
    return '/';
  } catch {
    return '/';
  }
}
