// Sign-in with another provider (Google now; Microsoft, Apple and Facebook ready behind the same switch). No imports:
// the pure parts of the flow, so the unit tests (oauth.test.ts) run them in plain Node with fakes.
//
// The flow: /auth/oauth?provider=google starts it (Supabase Auth's OAuth with PKCE: the code verifier goes in
// Supabase's own cookie on this browser, and this module's flow cookie keeps the provider and the page asked for),
// the provider sends the person to Supabase, Supabase back to /auth/callback?code=..., and finishOAuth() turns the code
// into the site's session cookie (the same cookie the password and phone sign-ins write), then does what a sign-up
// does for a new account and routes through the same afterSignIn() as a password sign-in (the two-step code for
// anyone who enrolled one, and setup for staff while the switch is on).
//
// Never by email alone: Supabase Auth links a provider sign-in to an existing account only when the provider says it
// verified the address, and then removes any unconfirmed identity of that account (a password someone set without
// confirming the address stops working). A provider sign-in whose address is not verified is refused here.

/** Our key for each provider, Supabase Auth's provider id, and the button's words. */
export const OAUTH_PROVIDERS = {
  google: { supabase: 'google', label: 'Google' },
  microsoft: { supabase: 'azure', label: 'Microsoft' },
  apple: { supabase: 'apple', label: 'Apple' },
  facebook: { supabase: 'facebook', label: 'Facebook' }
} as const;
export type OAuthProvider = keyof typeof OAUTH_PROVIDERS;
export const isOAuthProvider = (p: unknown): p is OAuthProvider => typeof p === 'string' && Object.hasOwn(OAUTH_PROVIDERS, p);

/** The providers switched on (AUTH_OAUTH_PROVIDERS, a comma list such as "google"), in the order of OAUTH_PROVIDERS.
 *  Empty or unset: none (the buttons are hidden and /auth/oauth refuses). */
export function enabledProviders(value: string | null | undefined): OAuthProvider[] {
  const on = new Set(String(value ?? '').toLowerCase().split(/[\s,]+/).filter(Boolean));
  return (Object.keys(OAUTH_PROVIDERS) as OAuthProvider[]).filter((p) => on.has(p));
}

/** The flow cookie: which provider, where to go after, sign-in or sign-up, and whether this is the second pass (an
 *  address on file from a booking request, see finishOAuth). `state` binds the local stand-in's code to this browser. */
export const FLOW_COOKIE = 'cc-oauth';
export const FLOW_MINUTES = 10;
export interface OAuthFlow { p: OAuthProvider; next: string | null; intent: 'signin' | 'signup'; again: boolean; state: string; t: number }

export function encodeFlow(f: OAuthFlow): string {
  return encodeURIComponent(JSON.stringify(f));
}
export function decodeFlow(raw: string | null | undefined, now = Date.now()): OAuthFlow | null {
  if (!raw) return null;
  try {
    const f = JSON.parse(decodeURIComponent(raw)) as Partial<OAuthFlow>;
    if (!isOAuthProvider(f.p) || typeof f.state !== 'string' || typeof f.t !== 'number') return null;
    if (now - f.t > FLOW_MINUTES * 60_000 || f.t - now > 60_000) return null;
    return { p: f.p, next: typeof f.next === 'string' ? f.next : null, intent: f.intent === 'signup' ? 'signup' : 'signin', again: f.again === true, state: f.state, t: f.t };
  } catch {
    return null;
  }
}

/** What the sign-in service answered for the code: the account now signed in on this browser. `fresh`: made by this
 *  very sign-in (only the provider's identity, created moments ago), so it holds nothing and may be replaced. */
export type OAuthExchange =
  | { ok: true; user: { id: string; email: string }; emailVerified: boolean; name: string | null; fresh: boolean }
  | { ok: false; message: string };

export interface FinishDeps {
  exchange(code: string, state: string): Promise<OAuthExchange>;
  signOut(): Promise<void>;
  /** public.register_account: the users row and the renter role (created false when the row exists). */
  registerAccount(id: string, email: string, name: string): Promise<{ ok: boolean; error?: string; created?: boolean }>;
  /** public.server_user_by_email: the id of a record on file with the address (a booking request, an owner record). */
  userByEmail(email: string): Promise<string | null>;
  /** Replaces the fresh sign-in with one for the record's id (address confirmed), so the next provider sign-in links to it. */
  relinkToRecord(freshId: string, recordId: string, email: string, name: string): Promise<boolean>;
  /** public.server_account_email_verified: earlier records attached, and the welcome email once (0040, 0045). */
  emailVerified(id: string, email: string): Promise<void>;
  /** A view-as left from an earlier session never carries over (as the password sign-in does). */
  clearSessionCookies(): Promise<void>;
  /** Sign-up from the create-account page closes this browser's capture of that form (0090). */
  signUpDone(): Promise<void>;
  /** The second step for anyone who enrolled one (or must, as staff), else the page asked for or their portal. */
  afterSignIn(id: string, next: string | null): Promise<string>;
}

export type FinishResult =
  | { kind: 'done'; to: string; user: string; created: boolean }
  | { kind: 'again'; to: string }
  | { kind: 'refused'; to: string; reason: 'exchange' | 'unverified' | 'record' | 'account' };

const refuse = (reason: 'exchange' | 'unverified' | 'record' | 'account', provider: OAuthProvider) =>
  ({ kind: 'refused', reason, to: `/sign-in?oauth=${reason}&provider=${provider}` }) as const;

/** The name a new account gets: the provider's, else the address before the @ (the profile page changes it). */
export function accountName(name: string | null | undefined, email: string): string {
  const n = String(name ?? '').replace(/\s+/g, ' ').trim();
  if (n.length >= 1 && n.length <= 120) return n;
  if (n.length > 120) return n.slice(0, 120).trim();
  return email.split('@')[0]!.slice(0, 120) || 'CarmaCars member';
}

/** The provider sent the person back with a code: the session, the account's rows, then the next page. */
export async function finishOAuth(deps: FinishDeps, code: string, flow: OAuthFlow): Promise<FinishResult> {
  const r = await deps.exchange(code, flow.state);
  if (!r.ok) return refuse('exchange', flow.p);
  const email = r.user.email.trim().toLowerCase();
  // the provider did not vouch for the address: nothing is linked or attached, and nobody stays signed in
  if (!r.emailVerified || !email) {
    await deps.signOut().catch(() => undefined);
    return refuse('unverified', flow.p);
  }
  await deps.clearSessionCookies();
  const name = accountName(r.name, email);
  let reg: { ok: boolean; error?: string; created?: boolean };
  try { reg = await deps.registerAccount(r.user.id, email, name); } catch { reg = { ok: false, error: 'failed' }; }
  if (!reg.ok && reg.error === 'email_on_record') {
    // A record with this address is on file without a sign-in (a guest's booking request). The provider verified the
    // address, as the emailed password link does for the create-account form: the fresh sign-in is replaced by one for
    // that record, and the person passes through the provider once more, which now links to it.
    const recordId = r.fresh && !flow.again ? await deps.userByEmail(email).catch(() => null) : null;
    await deps.signOut().catch(() => undefined);
    if (!recordId || recordId === r.user.id) return refuse('record', flow.p);
    if (!(await deps.relinkToRecord(r.user.id, recordId, email, name).catch(() => false))) return refuse('record', flow.p);
    const q = new URLSearchParams({ provider: flow.p, again: '1', intent: flow.intent });
    if (flow.next) q.set('next', flow.next);
    return { kind: 'again', to: `/auth/oauth?${q}` };
  }
  if (!reg.ok) {
    await deps.signOut().catch(() => undefined);
    return refuse('account', flow.p);
  }
  await deps.emailVerified(r.user.id, email).catch(() => undefined);
  if (flow.intent === 'signup') await deps.signUpDone().catch(() => undefined);
  const to = await deps.afterSignIn(r.user.id, flow.next);
  return { kind: 'done', to, user: r.user.id, created: reg.created === true };
}

/** The words the sign-in page shows for ?oauth=<reason>. */
export function oauthMessage(reason: string | null | undefined, provider: string | null | undefined): string | null {
  const label = isOAuthProvider(provider) ? OAUTH_PROVIDERS[provider].label : 'the provider';
  switch (reason) {
    case 'exchange': return `We could not finish signing you in with ${label}. Try again, or sign in with your email.`;
    case 'cancelled': return `Signing in with ${label} was cancelled. Try again, or sign in with your email.`;
    case 'unverified': return `${label} did not confirm your email address, so we could not sign you in with it. Sign in with your email instead.`;
    case 'record': return 'We already have a booking request with this email. Create an account with the same email (we email you a link to set your password), or contact us and we will link it.';
    case 'account': return 'We could not finish creating your account. Contact us and we will set it up.';
    case 'off': return `Signing in with ${label} is not available right now. Sign in with your email.`;
    default: return null;
  }
}
