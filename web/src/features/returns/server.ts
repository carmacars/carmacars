import { rpc } from '@/lib/db/repo';
import { UUID } from './claim';

// The database side of the "I've returned the car" link (migration 0532), as the service role: the token is the key.
export interface ClaimRead {
  booking_id: string; number: string; car: string | null; return_at: string; return_place: string | null; status: string;
  return_state: string | null; can_report: boolean; done: boolean;
  claim: { status: 'pending' | 'confirmed' | 'denied'; claimed_at: string; decision_note: string | null } | null;
}

export async function readClaim(token: string): Promise<ClaimRead | null> {
  if (!UUID.test(token)) return null;
  return ((await rpc('server_return_claim_read', { p_token: token }, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as ClaimRead | null) ?? null;
}
