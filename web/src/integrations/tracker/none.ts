import type { TrackerAdapter, TrackerResult } from './types';

// No tracker service is connected: every call says so and nothing is sent or made up.
const no = <T>(): Promise<TrackerResult<T>> => Promise.resolve({ ok: false, reason: 'not_connected', message: 'The tracker is not connected yet (coming soon).' });
export function noTracker(): TrackerAdapter {
  return { name: 'none', connected: false, locate: () => no(), requestImmobilize: () => no(), mileage: () => no() };
}
