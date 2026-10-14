import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { OwnerFormsTable, type FormRow } from '@/features/admin/OwnerForms';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner forms', path: '/va/owner-forms', noindex: true, description: 'Forms C and D signed with witnesses: review the uploads.' });

export default async function VaOwnerForms() {
  const { read } = await vaPage('/va/owner-forms', ['cs']);
  const rows = await read<FormRow[]>('owner_forms_queue');
  return (
    <>
      <PageHead title="Owner forms" kicker={`${rows.filter((r) => r.status === 'uploaded').length} waiting for review`} />
      <OwnerFormsTable rows={rows} base="/va" refresh={['/va/owner-forms']} />
    </>
  );
}
