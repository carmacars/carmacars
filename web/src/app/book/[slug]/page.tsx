import { notFound } from 'next/navigation';
import { Suspense } from 'react';
import { RequestWizard } from '@/features/booking/RequestWizard';
import { wizardProps } from '@/features/booking/wizard-props';
import { pageMeta } from '@/features/seo/meta';
import { fill, getFleet, getTokens } from '@/lib/site';

export const revalidate = 3600;
export const dynamicParams = true;
export async function generateStaticParams() { return (await getFleet()).map((c) => ({ slug: c.slug })); }
type Params = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug } = await params;
  const [t, fleet] = await Promise.all([getTokens(), getFleet()]);
  const c = fleet.find((x) => x.slug === slug);
  return pageMeta({ title: fill(`Request to book${c ? ` the ${c.make} ${c.model}` : ''} | {{brand}}`, t), path: `/book/${slug}`, noindex: true, description: fill('Send a booking request in four short steps. No payment and no card at request. We confirm the car and the price before you pay.', t) });
}
export default async function BookCar({ params }: Params) {
  const { slug } = await params;
  const props = await wizardProps(slug);
  if (!props.cars.some((c) => c.slug === slug)) notFound();
  return <div className="p-request"><Suspense fallback={null}><RequestWizard {...props} /></Suspense></div>;
}
