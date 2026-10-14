import type { TrackerAdapter } from './types';
import { noTracker } from './none';

// TRACKER_PROVIDER picks the adapter once a vendor's is written; today there is only "none".
export function tracker(): TrackerAdapter {
  return noTracker();
}
export type * from './types';
