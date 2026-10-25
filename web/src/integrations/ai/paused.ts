import 'server-only';
import { rpc } from '@/lib/db/repo';
import { roomCheck, type AiRoom } from './guard';

/** The day's Workers AI budget by tier (0133's app.ai_budget; 0080's usage guard underneath): read once per 20 seconds
 *  and kept current by what each call spent. A budget that cannot be read does not stop the features (as the phone
 *  line, 0085). */
export const aiRoom = roomCheck(async () => {
  const b = (await rpc('server_ai_budget', {}, { role: 'service_role' })) as unknown as { included?: number | string; used?: number | string; room?: Record<string, number | string> } | null;
  if (!b || !b.room) return null;
  return { included: Number(b.included ?? 0), used: Number(b.used ?? 0),
    room: { assistant: Number(b.room.assistant ?? 0), live: Number(b.room.live ?? 0), background: Number(b.room.background ?? 0) } } satisfies AiRoom;
});

/** Workers AI is stopped for the whole day (the included allowance used): the 0104 form, for callers without a purpose. */
export const workersAiPaused = () => aiRoom.paused();
