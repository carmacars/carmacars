import { PartnerLanding, VARIANTS } from '@/features/referral/PartnerLanding';
import { seoMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';

// The referral program for tow truck companies (migration 0164): what it pays, how it works, and the sign-up (a pending partner for an Admin).
export const revalidate = 3600;
const V = VARIANTS['tow-trucks'];
export async function generateMetadata() {
  return seoMeta({ title: 'Referral program for tow truck companies | CarmaCars', path: V.path,
    description: 'Send customers who need a rental car to CarmaCars and earn a fee on every rental that is completed and paid. Free to join, approved by a person, paid by e-Transfer or cheque.' });
}
export default async function Page() {
  const p = ((await rpc('referral_program_public', {}, { role: 'anon' }).catch(() => null)) as unknown as { flat_cents: number } | null) ?? { flat_cents: 5000 };
  return <PartnerLanding v={V} flatCents={p.flat_cents} />;
}
