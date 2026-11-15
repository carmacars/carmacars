import 'server-only';
import { env } from '@/lib/env';
import { relayFrom, type GeminiRelay } from '@/integrations/photos/gemini-route';

/** r48 (3030): the relay a Gemini call refused for its location goes through: GEMINI_RELAY_URL, else the database API's
 *  /gemini route on the company's server (Kong, service key only). null when the site has neither. */
export function geminiRelay(): GeminiRelay | null {
  const e = env();
  return relayFrom(e.NEXT_PUBLIC_SUPABASE_URL, e.SUPABASE_SERVICE_ROLE_KEY, e.GEMINI_RELAY_URL);
}
