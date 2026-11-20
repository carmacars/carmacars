import 'server-only';
import { getTrackerProduct, type TrackerProduct } from '@/features/tracker-product/data';
import { getSettings, getTokens } from '@/lib/site';
import type { TrackerFacts } from './pages';

/** The tracker's facts for its pages, the services module and llms.txt: Program settings and the site's name and city.
 *  Null when the product is switched off. */
export async function trackerFacts(): Promise<{ f: TrackerFacts; t: TrackerProduct } | null> {
  const [t, s, tok] = await Promise.all([getTrackerProduct(), getSettings(), getTokens()]);
  if (!t) return null;
  return { t, f: { name: t.name, brand: s.brand_name, city: s.city, tiers: t.tiers ?? [], installCents: t.install_cents, available: Boolean(t.available), launchNote: t.launch_note ?? 'Shipping soon', features: t.features, hst: tok.hst ?? '13%' } };
}
