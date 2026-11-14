// The key that signs the site's links, upload tickets, the jobs' token and the view-as cookie (src/server/links.ts).
// No imports, so the unit tests read it. LINK_SIGNING_KEY when set. Without it: production refuses to start (src/lib/env.ts);
// a local run uses LOCAL_AUTH_SECRET or the fixed local key; staging (a deployed site others can reach) uses
// LOCAL_AUTH_SECRET only: the fixed local key is written in this repository, so it never signs anything on a deployed site.
export const LOCAL_LINK_KEY = 'local-only-link-signing-key-not-for-production';

export interface LinkSecretEnv { LINK_SIGNING_KEY?: string; LOCAL_AUTH_SECRET?: string; APP_ENV?: string }

export function pickLinkSecret(e: LinkSecretEnv): string | undefined {
  if (e.LINK_SIGNING_KEY) return e.LINK_SIGNING_KEY;
  if (e.APP_ENV === 'production') return undefined;
  if (e.LOCAL_AUTH_SECRET) return e.LOCAL_AUTH_SECRET;
  return (e.APP_ENV ?? 'local') === 'local' ? LOCAL_LINK_KEY : undefined;
}
