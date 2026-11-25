import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { RenterState } from '@/features/checkins/model';

// Monthly check-in visits (migration 4000): what the signed-in renter sees for one booking. Nothing on any failure.
export async function renterCheckin(userId: string, booking: string): Promise<RenterState> {
  const r = (await rpc('server_checkin_renter' as never, { p_user: userId, p_booking: booking } as never, { role: 'service_role' }).catch(() => null)) as unknown as RenterState | null;
  return r ?? { on: false };
}
