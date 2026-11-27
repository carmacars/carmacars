import { pageMeta } from '@/features/seo/meta';
import { requireStaff, sessionAal } from '@/server/door';
import { OldPhotos } from '@/features/old-photos/OldPhotos';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add old photos', path: '/staff/field/old-photos', noindex: true, description: 'Add check-in and check-out photos still on your phone to past bookings.' });

// R50 hotfix 2 (5185): photos from earlier check-ins and check-outs that could not be uploaded then, onto any past booking.
export default async function FieldOldPhotos({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([requireStaff('field', '/staff/field/old-photos'), searchParams]);
  return (
    <>
      <header className="fd-home"><h1 className="fd-home__h">Add old photos</h1><p className="fd-home__sub">Check-in and check-out photos still on your phone, onto the past booking.</p></header>
      <OldPhotos userId={user.id} aal={await sessionAal()} base="/staff/field/old-photos" sp={sp} />
    </>
  );
}
