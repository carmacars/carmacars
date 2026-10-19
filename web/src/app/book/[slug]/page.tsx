import { notFound } from 'next/navigation';
import { Suspense } from 'react';
import { RequestWizard } from '@/features/booking/RequestWizard';
import { wizardProps } from '@/features/booking/wizard-props';
import { seoMeta } from '@/features/seo/meta';
import { fill, getFleet, getTokens } from '@/lib/site';

export const revalidate = 3600;
export const dynamicParams = true;
// on demand with the page cache, not at build time (see /cars/[slug])
export async function generateStaticParams() { return []; }
type Params = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug } = await params;
  const [t, fleet] = await Promise.all([getTokens(), getFleet()]);
  const c = fleet.find((x) => x.slug === slug);
  return seoMeta({ title: fill(`Request to book${c ? ` the ${c.make} ${c.model}` : ''} | {{brand}}`, t), path: `/book/${slug}`, noindex: true, description: fill('Send a booking request in four short steps. No payment and no card at request. We confirm the car and the price before you pay.', t) });
}
export default async function BookCar({ params }: Params) {
  const { slug } = await params;
  const [props, fleet] = await Promise.all([wizardProps(slug), getFleet()]);
  if (!props.cars.some((c) => c.slug === slug)) notFound();
  const car = fleet.find((c) => c.slug === slug);
  return (
    <div className="p-request">
      {/* a sample car (0065): the request goes to customer service as an enquiry for a similar real car */}
      {car?.is_sample && <div className="wrap"><p className="alert" role="note" data-testid="example-car-request-note"><span className="alert__title">Example car</span><span>The {car.make} {car.model} is an example of the cars we rent. Send your dates and details as usual: we reply with a similar real car and its price. Nothing is booked or charged.</span></p></div>}
      <Suspense fallback={null}><RequestWizard {...props} /></Suspense>
    </div>
  );
}
