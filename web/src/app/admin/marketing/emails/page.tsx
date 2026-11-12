import { pageMeta } from '@/features/seo/meta';
import { Card, PageHead } from '@/features/admin/ui';
import { page } from '@/server/admin/api';
import { rpc } from '@/lib/db/repo';
import { SaveForm } from '@/features/admin/Act';
import { fieldsFrom } from '@/features/admin/fields';
import { MARKETING_EMAIL_KEYS, MarketingEmailsView, type MarketingEmailsData } from '@/features/marketing-emails/MarketingEmailsView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Email campaigns', path: '/admin/marketing/emails', noindex: true, description: 'The marketing audience, the weekly email and the new car emails: waiting, queued, sent and unsubscribed.' });

// Admin > Marketing > Email campaigns (migration 2490). Sales sees the same page, read only, on Sales > Marketing.
export default async function AdminMarketingEmails() {
  const { user } = await page('/admin/marketing/emails');
  const d = (await rpc('server_marketing_emails', { p_user: user.id }, { role: 'service_role' })) as unknown as MarketingEmailsData;
  return (<>
    <PageHead title="Email campaigns" kicker="Marketing" purpose="Everyone who gave us their email on the site gets the weekly email and an email for each new car, unless they unsubscribed. The emails go within the free daily email budgets, after every booking email." />
    <MarketingEmailsView d={d} />
    <Card title="Switches and timing" testId="mkt-email-settings">
      <SaveForm table="program_settings" rowKey="current" testId="program-marketing-emails" fields={fieldsFrom(d.settings, MARKETING_EMAIL_KEYS)} />
      <p className="small muted">Saving writes a new dated row of Program settings from today. Day of the week: 1 is Monday, 7 is Sunday.</p>
    </Card>
  </>);
}
