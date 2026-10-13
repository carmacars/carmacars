import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead, label } from '@/features/admin/ui';
import { Scorecard, type Score } from '@/features/va/Scorecard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Scorecard', path: '/admin/staff', noindex: true, description: 'An assistant\'s weekly measures.' });

// An assistant's weekly scorecard for the Admin (05-va.md section 6, /admin/staff/[id]/scorecard).
export default async function StaffScorecard({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read } = await page(`/admin/staff/${id}/scorecard`);
  const s = await read<Score | null>('scorecard', { staff: id, weeks: 8 }).catch(() => null);
  if (!s) notFound();
  return (<><PageHead title={`Scorecard: ${s.name}`} kicker={<><Link prefetch={false} className="link" href="/admin/settings/staff">Staff</Link> · {label(s.function)}</>} /><Scorecard s={s} /></>);
}
