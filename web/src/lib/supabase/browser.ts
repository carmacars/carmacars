'use client';
import { createBrowserClient } from '@supabase/ssr';
import { publicEnv } from '@/lib/public-env';
import type { Database } from '@/lib/db/types';

// The browser client: anon key, row-level security applies. Used for the public reads the
// blueprint puts in the browser (calendar, quote, search, cookie choice) when DATA_BACKEND=supabase.
let client: ReturnType<typeof createBrowserClient<Database>> | undefined;
export function supabaseBrowser() {
  client ??= createBrowserClient<Database>(publicEnv.supabaseUrl, publicEnv.supabaseAnonKey,
    publicEnv.supabaseAuthCookie ? { cookieOptions: { name: publicEnv.supabaseAuthCookie } } : undefined);
  return client;
}
