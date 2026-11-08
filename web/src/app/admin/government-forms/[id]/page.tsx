import { pageMeta } from '@/features/seo/meta';
import { GovFormPage } from '@/features/onboarding/GovFormPage';
import { staffFillOr404 } from '@/server/government-forms';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Government form', path: '/admin/government-forms', noindex: true, description: 'One government form of an owner\'s car, filled from the records.' });

// One government form of an owner's car (r34, 0822; r35, 0870): the official form, its values and its versions.
export default async function AdminGovernmentForm({ params }: { params: Promise<{ id: string }> }) {
  return <GovFormPage f={await staffFillOr404((await params).id)} base="/admin" />;
}
