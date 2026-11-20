import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';

// The GPS tracker product (release 36, migration 2003; release 48, migration 3231), from Program settings: null when it
// is switched off. `tiers` is the monthly price per car by the number of cars; `available` is false until trackers can be
// installed (the pages then show the waitlist and never say a tracker is in stock).
export interface TrackerTier { from_cars: number; to_cars: number | null; monthly_cents: number }
export interface TrackerProduct { name: string; monthly_cents: number | null; install_cents: number | null; features: Array<{ title: string; text: string }>; details: string | null;
  tiers?: TrackerTier[]; available?: boolean; launch_note?: string; hst_bps?: number }
export const getTrackerProduct = cache(async (): Promise<TrackerProduct | null> => {
  try { return ((await rpc('tracker_product', {})) ?? null) as unknown as TrackerProduct | null; } catch { return null; }
});
export interface InstallPlace { slug: string; name: string; km: number }
/** The Ontario cities whose install page the product page links and the sitemap lists (nearest first). */
export const getInstallPlaces = cache(async (limit = 60): Promise<InstallPlace[]> => {
  try { return ((await rpc('tracker_install_places', { p_limit: limit }, { role: 'service_role' })) ?? []) as unknown as InstallPlace[]; } catch { return []; }
});
