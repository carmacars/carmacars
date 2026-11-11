import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';

// The GPS tracker product (release 36, migration 2003), from Program settings: null when it is switched off.
export interface TrackerProduct { name: string; monthly_cents: number | null; install_cents: number | null; features: Array<{ title: string; text: string }>; details: string | null }
export const getTrackerProduct = cache(async (): Promise<TrackerProduct | null> => {
  try { return ((await rpc('tracker_product', {})) ?? null) as unknown as TrackerProduct | null; } catch { return null; }
});
