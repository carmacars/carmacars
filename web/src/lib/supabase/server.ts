import 'server-only';
import { cookies } from 'next/headers';
import { createServerClient } from '@supabase/ssr';
import { required } from '@/lib/env';
import type { Database } from '@/lib/db/types';

// Supabase Auth on the server (sign-in, sign-up, reset), with the session in cookies (@supabase/ssr).
export async function supabaseServer() {
  const store = await cookies();
  return createServerClient<Database>(required('NEXT_PUBLIC_SUPABASE_URL'), required('NEXT_PUBLIC_SUPABASE_ANON_KEY'), {
    cookies: {
      getAll: () => store.getAll(),
      setAll: (list) => {
        try {
          for (const { name, value, options } of list) store.set(name, value, options);
        } catch {
          // Called from a server component, where cookies are read-only. Sign-in actions set them.
        }
      }
    }
  });
}
