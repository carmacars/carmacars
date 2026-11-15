import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter guide', path: '/staff/guide/renter', noindex: true, description: 'The renter guide as renters read it, for staff who help them.' });

// 2990: the renter guide inside the staff portal (office and field staff), so the academy's path The renter's side and staff
// helping a renter open the exact page the renter reads. Opening it here is not counted as a renter's read.
export default async function StaffRenterGuide() {
  const { user } = await academyUser('/staff/guide/renter');
  return (<>
    <p className="small muted gd-noprint" data-testid="staff-renter-guide">The renter guide, as renters read it in their account. Send a renter the chapter that answers their question.</p>
    <GuideView g={await guideFor(user, 'renter', false)} portal="renter" pdfHref="/guide-pdf/renter" />
  </>);
}
