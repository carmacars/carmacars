import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { DataIssue } from '@/features/data-checks/model';

// r48 FE (3197): the data checks of the signed-in person's own record (the pop-up on every portal page).
const SR = { role: 'service_role' as const, skipViewAs: true };
export async function dataChecks(userId: string | null | undefined, audience?: 'staff' | 'owner' | 'renter'): Promise<DataIssue[]> {
  if (!userId) return [];
  const all = ((await rpc('server_data_checks', { p_user: userId }, SR).catch(() => [])) ?? []) as unknown as DataIssue[];
  return audience ? all.filter((x) => x.audience === audience) : all;
}
