import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { vaPage } from '@/server/va';
import { rpc } from '@/lib/db/repo';
import { MarketingEmailsView, type MarketingEmailsData } from '@/features/marketing-emails/MarketingEmailsView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Email campaigns', path: '/staff/marketing/emails', noindex: true, description: 'The marketing audience, the weekly email and the new car emails: waiting, queued, sent and unsubscribed.' });

// Sales > Marketing > Email campaigns (migration 2490): the Admin's Marketing > Email campaigns page, read only. The database
// checks the person again.
export default async function StaffMarketingEmails() {
  const { user } = await vaPage('/staff/marketing/emails', ['sales']);
  const d = (await rpc('server_marketing_emails', { p_user: user.id }, { role: 'service_role' })) as unknown as MarketingEmailsData;
  return (<>
    <PageHead title="Email campaigns" kicker="Marketing" purpose="Everyone who gave us their email on the site gets the weekly email and an email for each new car, unless they unsubscribed. Read only: the Admin changes the switches." />
    <MarketingEmailsView d={d} />
  </>);
}
