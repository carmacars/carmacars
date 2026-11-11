import 'server-only';
import { door } from '@/server/door';
import type { SelfProfileData } from '@/features/portal/SelfProfile';

/** The signed-in person's own profile card (migration 0812, app.self_profile_view). */
export async function selfProfile(userId: string): Promise<SelfProfileData | null> {
  return door<SelfProfileData>(userId, 'ops_read', 'self_profile', {}).catch(() => null);
}

/** The name changes waiting for an Admin, for one person's page (an owner, investor, renter or user id) or all (migration 0812). */
export type NameChange = { id: string; user_id: string; current_name: string; requested_name: string; reason: string | null; requested_at: string;
  /** r35 UX (1110): a renter's date of birth correction */ current_dob?: string | null; requested_dob?: string | null };
export async function nameChangesFor(adminId: string, who: Record<string, string> = {}): Promise<NameChange[]> {
  return door<NameChange[]>(adminId, 'ops_read', 'name_change_pending', who).catch(() => []);
}
