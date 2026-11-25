import { pageMeta } from '@/features/seo/meta';
import { requireStaff, sessionAal, door } from '@/server/door';
import { CheckinQueue } from '@/features/checkins/Queue';
import type { Queue } from '@/features/checkins/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Check-in visits', path: '/staff/field/check-ins', noindex: true, description: 'Monthly check-in visits to do at the car.' });

// Release 50 (4000): field work does the visit at the car, on the phone.
export default async function FieldCheckins({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireStaff('field', '/staff/field/check-ins'), searchParams]);
  const q = await door<Queue>(user.id, 'field_read', 'checkin_queue', {}, await sessionAal());
  return (
    <>
      <header className="fd-home"><h1 className="fd-home__h">Check-in visits</h1><p className="fd-home__sub">Monthly visits of long rentals: photos, damage, tires, fluids.</p></header>
      <CheckinQueue q={q} base="/staff/field" show={sp.show} />
    </>
  );
}
