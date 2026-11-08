import 'server-only';
import { door, type Call } from '@/server/door';
import type { Overview } from '@/features/onboarding/steps';
import type { PhotoRow } from '@/features/onboarding/OnboardingPhotos';
import type { GovData } from '@/features/onboarding/GovernmentForms';

// The reads of the one Onboarding checklist, the onboarding photos and the government forms (r34, 0821 to 0823), for the
// owner portal (ops_read with the owner's account), an Admin (ops_read) or staff (va_read). Each read is refused by the
// database for someone who may not see it; a page then shows the rest.
export interface OnboardingData { overview: Overview | null; photos: PhotoRow[]; forms: GovData | null }

export async function onboardingData(userId: string, call: Call, p: { owner_id: string; vehicle_id?: string }): Promise<OnboardingData> {
  const [overview, photos, forms] = await Promise.all([
    door<Overview>(userId, call, 'onboarding_overview', p).catch(() => null),
    door<PhotoRow[]>(userId, call, 'onboarding_photos', p).catch(() => [] as PhotoRow[]),
    door<GovData>(userId, call, 'government_forms', p).catch(() => null)]);
  return { overview, photos: photos ?? [], forms };
}
