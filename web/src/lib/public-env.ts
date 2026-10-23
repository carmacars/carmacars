// The public part of the environment (inlined into the browser bundle at build time).
export const publicEnv = {
  appUrl: process.env.NEXT_PUBLIC_APP_URL ?? 'http://localhost:3000',
  dataBackend: (process.env.NEXT_PUBLIC_DATA_BACKEND ?? 'local') as 'local' | 'supabase',
  supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL ?? '',
  supabaseAnonKey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? '',
  /** The session cookie's name when it must not follow the Supabase address (server.ts). */
  supabaseAuthCookie: process.env.NEXT_PUBLIC_SUPABASE_AUTH_COOKIE ?? '',
  photosUrl: (process.env.NEXT_PUBLIC_VEHICLE_PHOTOS_URL ?? '/_local/vehicle-public').replace(/\/$/, ''),
  turnstileSiteKey: process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? '1x00000000000000000000AA',
  turnstileMode: (process.env.NEXT_PUBLIC_TURNSTILE_PROVIDER ?? 'fake') as 'cloudflare' | 'fake' | 'off'
};
