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
  NEXT_PUBLIC_VEHICLE_PHOTOS_URL: z.string().default('/_local/vehicle-public'),
  TURNSTILE_PROVIDER: z.enum(['cloudflare', 'fake']).default('fake'),
  NEXT_PUBLIC_TURNSTILE_SITE_KEY: z.string().default('1x00000000000000000000AA'),
  TURNSTILE_SECRET_KEY: z.string().default('1x0000000000000000000000000000000AA'),
  PAYMENTS_PROVIDER: z.enum(['stripe', 'fake']).default('fake'),
  STRIPE_SECRET_KEY: z.string().optional(),
  STORAGE_PROVIDER: z.enum(['r2', 'local']).default('local'),
  R2_ACCOUNT_ID: z.string().optional(),
  R2_ACCESS_KEY_ID: z.string().optional(),
  R2_SECRET_ACCESS_KEY: z.string().optional(),
  R2_BUCKET_PREFIX: z.string().default('carmacars-local-'),
  MAPS_PROVIDER: z.enum(['google', 'fake']).default('fake'),
  GOOGLE_MAPS_API_KEY: z.string().optional()
});

export type ServerEnv = z.infer<typeof schema>;
let cached: ServerEnv | undefined;

export function env(): ServerEnv {
  if (cached) return cached;
  const e = schema.parse(process.env);
  if (e.APP_ENV === 'production') {
    if (e.DATA_BACKEND !== 'supabase') throw new Error('Production runs on Supabase (DATA_BACKEND=supabase).');
    if (e.TURNSTILE_PROVIDER !== 'cloudflare') throw new Error('Production checks public forms with Cloudflare Turnstile.');
  }
  cached = e;
  return e;
}

export function required<K extends keyof ServerEnv>(key: K): NonNullable<ServerEnv[K]> {
  const v = env()[key];
  if (v === undefined || v === null || v === '') throw new Error(`Missing environment variable ${String(key)} (see web/.env.example)`);
  return v as NonNullable<ServerEnv[K]>;
}
