import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { requireAdmin } from '@/server/admin/data';
import { PageHead } from '@/features/admin/ui';
import { PushAlerts } from '@/features/push/PushAlerts';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My phone alerts', path: '/admin/alerts', noindex: true, description: 'Alerts on your phone or computer for new requests, payments, messages and urgent problems.' });

// Phone and browser alerts (migration 0300): the Admin's own devices and topics. Staff, owners, renters and investors
// have the same card on their profile.
export default async function AdminAlerts() {
  const { user } = await requireAdmin('/admin/alerts');
  const card = await PushAlerts({ userId: user.id, portal: 'admin', className: 'pt-card stack' });
  return (
    <>
      <PageHead title="My phone alerts" />
      <div className="stack-lg" style={{ maxWidth: '44rem' }}>
        {card ?? (
          <section className="pt-card stack" data-testid="push-off-setup">
            <h2 className="d4">Phone alerts are not set up yet</h2>
            <p className="small">They need the two VAPID keys in the vault: <code>deploy_vapid_public_key</code> and <code>deploy_vapid_private_key</code>. The next deploy then turns the alerts cards on in every portal.</p>
          </section>
        )}
        <p className="small muted">Emails and texts are unchanged. How customers are reached: <Link prefetch={false} className="link" href="/admin/settings/text-alerts">Settings &gt; Text alerts</Link>.</p>
      </div>
    </>
  );
}
