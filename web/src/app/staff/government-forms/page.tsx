import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { OfficialForms, type FormsData } from '@/features/official-forms/OfficialForms';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Government forms', path: '/staff/government-forms', noindex: true, description: 'The official ServiceOntario forms and which value goes in each box.' });

// r35 (0870): fleet maps the official ServiceOntario forms as an Admin does in Settings > Forms (only an Admin uploads one).
export default async function VaGovernmentForms() {
  const { user, aal } = await vaPage('/staff/government-forms', ['fleet']);
  const d = await door<FormsData>(user.id, 'ops_read', 'form_templates', {}, aal);
  return (
    <>
      <PageHead title="Government forms" kicker="Which value goes in each box of the official forms" />
      <OfficialForms d={d} path="/staff/government-forms" />
    </>
  );
}
