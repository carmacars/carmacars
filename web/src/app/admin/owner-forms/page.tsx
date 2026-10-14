import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { OwnerFormsTable, type FormRow } from '@/features/admin/OwnerForms';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner forms', path: '/admin/owner-forms', noindex: true, description: 'Forms C and D signed with witnesses: review the uploads.' });

export default async function OwnerForms() {
  const { read } = await page('/admin/owner-forms');
  const rows = await read<FormRow[]>('owner_forms_queue');
  return (
    <>
      <PageHead title="Owner forms" kicker={`${rows.filter((r) => r.status === 'uploaded').length} waiting for review`} />
      <p className="small muted">Form C for each financed or leased car and Form D once per owner, signed on paper with witnesses and uploaded by the owner.</p>
      <OwnerFormsTable rows={rows} base="/admin" refresh={['/admin/owner-forms']} />
    </>
  );
}
