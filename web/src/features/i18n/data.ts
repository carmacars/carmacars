import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import { LANG_CODES } from './catalog';

// The languages of the search pages (release 36, part 2; migration 2004).
export interface Lang { code: string; name: string; native_name: string; hreflang: string; dir: 'ltr' | 'rtl'; coverage_bps: number; ready: boolean }
export const getLanguages = cache(async (): Promise<Lang[]> => { try { return (((await rpc('seo_languages_state', {})) ?? []) as unknown as Lang[]); } catch { return []; } });
export const getLang = cache(async (code: string): Promise<Lang | null> => (LANG_CODES.has(code) ? (await getLanguages()).find((l) => l.code === code) ?? null : null));
export const getBundle = cache(async (code: string): Promise<Record<string, string>> => {
  try { return ((((await rpc('seo_i18n_bundle', { p_lang: code })) as unknown as { strings?: Record<string, string> } | null)?.strings) ?? {}); } catch { return {}; }
});

/** The hreflang alternates of a page that has language versions: English (en-CA, x-default) and each ready language. */
export async function langAlternates(path: string, base: string): Promise<Record<string, string>> {
  const langs = (await getLanguages()).filter((l) => l.ready);
  return { 'en-CA': base + path, 'x-default': base + path, ...Object.fromEntries(langs.map((l) => [l.hreflang, `${base}/${l.code}${path}`])) };
}
