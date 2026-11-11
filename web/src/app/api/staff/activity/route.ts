import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// 1800: the office staff's activity beat (ActivityBeat.tsx), at most once a minute from the browser and once a minute in
// the database. No body: only the fact of activity. The answer says whether the person is counted now.
export const dynamic = 'force-dynamic';
export async function POST() {
  const user = await currentUser();
  if (!user) return new Response(null, { status: 204 });
  const v = await door<{ tracking: boolean; nudge_minutes: number }>(user.id, 'ops_do', 'va_activity', {}).catch(() => null);
  return Response.json(v ?? { tracking: false });
}
