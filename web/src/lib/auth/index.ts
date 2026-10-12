import 'server-only';
import { env } from '@/lib/env';
import type { AuthAdapter } from './types';

// Sign-in is Supabase Auth. The local stack has no GoTrue, so src/lib/auth/local.ts stands in
// for it with the same behaviour (email and password, reset by email, cookie session).
let adapter: Promise<AuthAdapter> | undefined;
export function auth(): Promise<AuthAdapter> {
  adapter ??= env().DATA_BACKEND === 'local'
    ? import('./local').then((m) => m.localAuth())
    : import('./supabase').then((m) => m.supabaseAuth());
  return adapter;
}
export type { SessionUser, AuthResult } from './types';
