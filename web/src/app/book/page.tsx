import { Suspense } from 'react';
import { RequestWizard } from '@/features/booking/RequestWizard';
import { wizardProps } from '@/features/booking/wizard-props';
import { seoMeta } from '@/features/seo/meta';
import { fill, getTokens } from '@/lib/site';

export const revalidate = 3600;
export async function generateMetadata() {
  const t = await getTokens();
  return seoMeta({ title: fill('Request to book | {{brand}}', t), path: '/book', noindex: true, description: fill('Send a booking request to {{brand}} in four short steps. No payment and no card at request. We confirm the car and the price before you pay.', t) });
}
export default async function Book() {
  const props = await wizardProps(null);
  return <div className="p-request"><Suspense fallback={null}><RequestWizard {...props} /></Suspense></div>;
}
