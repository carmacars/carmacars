import 'server-only';
import { after } from 'next/server';

// Right after a car is added (migration 0082), once the response has gone: the search job writes its title,
// description and features (car-copy-v2, the car's copy row is asked for first), then the details that come later
// (a VIN decoded again, the colour from a cover photo). The five-minute ticks do the same if this does not run.
export function afterCarAdded(): void {
  try {
    after(async () => {
      const { runSeoJobNow } = await import('@/server/seo-job');
      await runSeoJobNow({ limit: 2, deadlineMs: 25_000 }).catch(() => undefined);
      const { runCarDetailsNow } = await import('@/server/car-details');
      await runCarDetailsNow({ vins: 1, colours: 1 }).catch(() => undefined);
    });
  } catch { /* outside a request: the five-minute ticks take it */ }
}
