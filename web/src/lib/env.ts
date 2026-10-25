import 'server-only';
import { z } from 'zod';

// Typed server environment, matching web/.env.example. Read once, on first use, so a build
// without a value it does not need still works; a value that is needed and missing names itself.
const schema = z.object({
  APP_ENV: z.enum(['local', 'staging', 'production']).default('local'),
  DATA_BACKEND: z.enum(['local', 'supabase']).default('local'),
  NEXT_PUBLIC_APP_URL: z.string().url().default('http://localhost:3000'),
  DATABASE_URL: z.string().optional(),
  LOCAL_AUTH_SECRET: z.string().min(32).optional(),
  NEXT_PUBLIC_SUPABASE_URL: z.string().optional(),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z.string().optional(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().optional(),
  /** The project's JWT secret (legacy HS256 key, still accepted by the database API): Admin "view as" reads a renter's
   *  or owner's portal with a 5-minute token for that person, made on the server (src/server/view-as.ts). */
  SUPABASE_JWT_SECRET: z.string().optional(),
  NEXT_PUBLIC_VEHICLE_PHOTOS_URL: z.string().default('/_local/vehicle-public'),
  /** off: no widget, no check (only until the Turnstile widget exists; the database rate limits still apply) */
  TURNSTILE_PROVIDER: z.enum(['cloudflare', 'fake', 'off']).default('fake'),
  NEXT_PUBLIC_TURNSTILE_SITE_KEY: z.string().default('1x00000000000000000000AA'),
  TURNSTILE_SECRET_KEY: z.string().default('1x0000000000000000000000000000000AA'),
  PAYMENTS_PROVIDER: z.enum(['stripe', 'fake']).default('fake'),
  STRIPE_SECRET_KEY: z.string().optional(),
  STRIPE_WEBHOOK_SECRET: z.string().optional(),
  NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY: z.string().optional(),
  /** Signs links that act without a session (additional drivers' signing links, upload tickets, local storage links). */
  LINK_SIGNING_KEY: z.string().min(32).optional(),
  /** r2: S3 API with R2_* keys; r2-binding: the Worker's R2 bindings (signed links through /api/storage);
   *  supabase: Supabase Storage (for a Cloudflare account without R2) */
  STORAGE_PROVIDER: z.enum(['r2', 'r2-binding', 'supabase', 'local']).default('local'),
  R2_ACCOUNT_ID: z.string().optional(),
  R2_ACCESS_KEY_ID: z.string().optional(),
  R2_SECRET_ACCESS_KEY: z.string().optional(),
  R2_BUCKET_PREFIX: z.string().default('carmacars-local-'),
  MAPS_PROVIDER: z.enum(['google', 'fake']).default('fake'),
  GOOGLE_MAPS_API_KEY: z.string().optional(),
  VIN_DECODER: z.enum(['vpic', 'fake']).default('fake'),
  /** The listing pipeline: copy drafts (workers-ai: the Worker's AI binding) and photos (cloudflare: Images transformations). */
  LLM_PROVIDER: z.enum(['workers-ai', 'fake']).default('fake'),
  PHOTO_PROVIDER: z.enum(['cloudflare', 'fake']).default('fake'),
  PHOTO_FAKE_MODE: z.enum(['ok', 'not_enabled']).default('ok'),
  PAYOUT_ENCRYPTION_KEY: z.string().min(32).optional(),
  /** The business phone line (migration 0085): quo sends texts through Quo's API with QUO_API_KEY (CarmaCars' own Quo
   *  account only); fake records them without sending (local work and tests). */
  QUO_PROVIDER: z.enum(['quo', 'fake']).default('fake'),
  QUO_API_KEY: z.string().optional(),
  QUO_API_BASE: z.string().url().optional(),
  /** The signing secret of our Quo webhook (whsec_...), made by the deploy (scripts/deploy/quo.mjs) and kept in the vault. */
  QUO_WEBHOOK_SECRET: z.string().optional(),
  /** Sign-in by phone (migration 0091): the Standard Webhooks secret ("v1,whsec_...") of Supabase Auth's Send SMS hook,
   *  made by the deploy (scripts/deploy/supabase.sh smshook) and kept in the vault. Locally the stand-in's fixed secret. */
  AUTH_SMS_HOOK_SECRET: z.string().optional(),
  /** Sign-in with a provider (src/lib/auth/oauth.ts): a comma list of google, microsoft, apple, facebook. Unset: none
   *  (no buttons). Each needs its provider switched on in Supabase Auth first; locally the stand-in fakes them. */
  AUTH_OAUTH_PROVIDERS: z.string().default(''),
  /** The Google reviews sync (migration 0138): the OAuth client of the Google Cloud project that has the Business Profile
   *  APIs (a Web application client, redirect URI <site>/api/google/reviews/callback). Unset: Admin > Settings > Reviews
   *  says so and the rest of the review program works. The refresh token itself is in the vault, never here. */
  GOOGLE_REVIEWS_CLIENT_ID: z.string().optional(),
  GOOGLE_REVIEWS_CLIENT_SECRET: z.string().optional()
});

export type ServerEnv = z.infer<typeof schema>;
let cached: ServerEnv | undefined;

export function env(): ServerEnv {
  if (cached) return cached;
  // an empty value (KEY= in an env file) counts as not set
  const e = schema.parse(Object.fromEntries(Object.entries(process.env).filter(([, v]) => v !== '')));
  if (e.APP_ENV === 'production') {
    if (e.DATA_BACKEND !== 'supabase') throw new Error('Production runs on Supabase (DATA_BACKEND=supabase).');
    if (e.TURNSTILE_PROVIDER === 'fake') throw new Error('Production checks public forms with Cloudflare Turnstile (or has it off), never the fake.');
    if (e.PAYMENTS_PROVIDER !== 'stripe') throw new Error('Production takes payments through Stripe (PAYMENTS_PROVIDER=stripe).');
    if (!e.LINK_SIGNING_KEY) throw new Error('Production needs LINK_SIGNING_KEY.');
  }
  cached = e;
  return e;
}

export function required<K extends keyof ServerEnv>(key: K): NonNullable<ServerEnv[K]> {
  const v = env()[key];
  if (v === undefined || v === null || v === '') throw new Error(`Missing environment variable ${String(key)} (see web/.env.example)`);
  return v as NonNullable<ServerEnv[K]>;
}
