import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { PageHead, Tabs } from '@/features/admin/ui';
import { PushAlerts } from '@/features/push/PushAlerts';
import { AppProfile } from '@/features/app-shell/AppProfile';
import { inAppShell } from '@/server/app-shell';
import { AlertsFeed } from '@/features/alerts/AlertsFeed';
import { AlertSettings } from '@/features/alerts/AlertSettings';
import { filterOf } from '@/features/alerts/types';
import { alertFeed, alertPrefs, alertRules, alertUnread } from '@/server/alerts';
import { AlertRules } from '@/features/alerts/AlertRules';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Alerts', path: '/admin/alerts', noindex: true, description: 'Every alert for you, and how they reach your phone.' });

// The Admin's Alerts (migration 0466), behind the bell: the feed of every staff alert (leads, requests, the booking steps,
// money, field work, documents, customers, owners, the system, wins), and the settings: phone alerts and their topics
// (0300), quiet hours and focus mode. Which alerts exist and who gets them: docs/alerts/matrix.md.
export default async function AdminAlerts({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { user } = await requireAdmin('/admin/alerts');
  const settings = sp.tab === 'settings';
  const filter = filterOf(sp.f);
  const [items, unread] = settings ? [[], await alertUnread(user.id)] : await Promise.all([alertFeed(user.id, filter), alertUnread(user.id)]);
  return (
    <>
      <PageHead title="Alerts" />
      <Tabs items={[['/admin/alerts', 'Alerts', unread], ['/admin/alerts?tab=settings', 'Settings']]} current={settings ? '/admin/alerts?tab=settings' : '/admin/alerts'} />
      <div className="stack-lg" style={{ maxWidth: '48rem' }}>
        {settings ? <Settings userId={user.id} /> : <AlertsFeed key={filter} initial={items} filter={filter} base="/admin/alerts" />}
      </div>
    </>
  );
}

async function Settings({ userId }: { userId: string }) {
  const [card, prefs, app, rules] = await Promise.all([PushAlerts({ userId, portal: 'admin', className: 'pt-card stack' }), alertPrefs(userId), inAppShell(), alertRules(userId)]);
  return (
    <>
      {card ?? (
        <section className="pt-card stack" data-testid="push-off-setup">
          <h2 className="d4">Phone alerts are not set up yet</h2>
          {app
            ? <p className="small">Alerts in the CarmaCars app need the Firebase service account in the vault: <code>deploy_fcm_service_account</code> (docs/apps/publish.md). The next deploy then turns them on in the app.</p>
            : <p className="small">The next deploy makes their two keys by itself and turns the alerts cards on in every portal. Nothing to do: if this stays after a deploy, the deploy&apos;s run says why.</p>}
        </section>
      )}
      {prefs && <AlertSettings initial={prefs} />}
      {rules.length > 0 && <AlertRules initial={rules} />}
      <AppProfile userId={userId} lock className="pt-card stack" />
      <p className="small muted">The money threshold, escalation, briefs, grouping and complaint words, and emails and texts to customers: <Link prefetch={false} className="link" href="/admin/settings/text-alerts">Settings &gt; Text alerts</Link>.</p>
    </>
  );
}
