import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { redirect } from 'next/navigation';
import { requireStaff, rolesOf } from '@/server/door';
import { PageHead, Tabs } from '@/features/admin/ui';
import { PushAlerts } from '@/features/push/PushAlerts';
import { AlertsFeed } from '@/features/alerts/AlertsFeed';
import { AlertSettings } from '@/features/alerts/AlertSettings';
import { filterOf } from '@/features/alerts/types';
import { alertFeed, alertPrefs, alertUnread } from '@/server/alerts';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Alerts', path: '/staff/alerts', noindex: true, description: 'Every alert for you, and how they reach your phone.' });

// A staff member's Alerts (migration 0466), behind the bell: what concerns them (their leads, the work of their function
// on duty, their jobs, the morning brief, urgent alerts passed to them), and their settings: phone alerts and topics,
// quiet hours and focus mode. Office staff and field staff alike.
export default async function StaffAlerts({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const me = await currentUser();
  if (!me) redirect('/sign-in?next=/staff/alerts');
  const office = !!(await rolesOf(me.id).catch(() => null))?.va;
  const { user } = await requireStaff(office ? 'va' : 'field', '/staff/alerts');
  const settings = sp.tab === 'settings';
  const filter = filterOf(sp.f);
  const [items, unread, prefs] = await Promise.all([settings ? Promise.resolve([]) : alertFeed(user.id, filter), alertUnread(user.id), settings ? alertPrefs(user.id) : Promise.resolve(null)]);
  return (
    <>
      <PageHead title="Alerts" />
      <Tabs items={[['/staff/alerts', 'Alerts', unread], ['/staff/alerts?tab=settings', 'Settings']]} current={settings ? '/staff/alerts?tab=settings' : '/staff/alerts'} />
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        {settings ? (
          <>
            <PushAlerts userId={user.id} portal={office ? 'staff' : 'field'} className="pt-card stack" />
            {prefs && <AlertSettings initial={prefs} />}
          </>
        ) : <AlertsFeed key={filter} initial={items} filter={filter} base="/staff/alerts" />}
      </div>
    </>
  );
}
