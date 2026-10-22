import 'server-only';
import { rpc } from '@/lib/db/repo';
import { cachedCheck } from './guard';

/** Workers AI is paused (0080's usage_gate): the service's state is paused or held, or all AI use of the day reached the
 *  cap. A guard that cannot be read does not stop the features (as the phone line, 0085). */
export const workersAiPaused = cachedCheck(async () => {
  try {
    const g = (await rpc('server_usage_gate', { p_service: 'workers_ai' }, { role: 'service_role' })) as unknown as { paused?: boolean; used?: number | string; all_cap?: number | string };
    return g.paused === true || (g.all_cap !== undefined && g.used !== undefined && Number(g.used) >= Number(g.all_cap));
  } catch { return false; }
});
