import 'server-only';
import { rpc } from '@/lib/db/repo';

// Guide me (migration 3950): what Admin > Academy shows, the last 30 days.
export type GuideMeReport = {
  staff: Array<{ id: string; name: string; on: boolean; started: number; completed: number; exited: number; active: number; last: string | null; flows: string[] }>;
  flows: Array<{ flow: string; started: number; completed: number; drop_off: { step: string; n: number } | null }>;
};

export async function guideMeReport(adminId: string): Promise<GuideMeReport> {
  const r = (await rpc('guide_me_report', { p_by: adminId }, { role: 'service_role' }).catch(() => null)) as unknown as GuideMeReport | null;
  return r ?? { staff: [], flows: [] };
}
