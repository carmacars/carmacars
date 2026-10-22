import { notFound } from 'next/navigation';
import { Suspense } from 'react';
import { RequestWizard } from '@/features/booking/RequestWizard';
import { bookingCar, wizardProps } from '@/features/booking/wizard-props';
import { seoMeta } from '@/features/seo/meta';
import { fill, getTokens } from '@/lib/site';

export const revalidate = 3600;
export const dynamicParams = true;
// on demand with the page cache, not at build time (see /cars/[slug])
export async function generateStaticParams() { return []; }
type Params = { params: Promise<{ slug: string }> };

export async function generateMetadata({ params }: Params) {
  const { slug } = await params;
  const [t, c] = await Promise.all([getTokens(), bookingCar(slug)]);
  return seoMeta({ title: fill(`Request to book${c ? ` the ${c.name}` : ''} | {{brand}}`, t), path: `/book/${slug}`, noindex: true, description: fill('Send a booking request in four short steps. No payment and no card at request. We confirm the car and the price before you pay.', t) });
}
// 0102: the form renders on the server with its car (the summary beside it shows at once); the price is asked from the
// browser as soon as the dates are known. The car list is one light call (public.booking_cars), not the fleet's rows.
export default async function BookCar({ params }: Params) {
  const { slug } = await params;
  const props = await wizardProps(slug);
  const car = props.initialCar;
  if (!car) notFound();
  return (
    <div className="p-request">
      {/* a sample car (0065): the request goes to customer service as an enquiry; 0102: a real car free for the dates is offered in the form */}
      {car.isSample && <div className="wrap"><p className="alert" role="note" data-testid="example-car-request-note"><span className="alert__title">Example car</span><span>The {car.name} is an example of the cars we rent. Choose your dates: if a real one is free, we show it here. If not, send your dates and details as usual and we reply with a similar real car and its price. Nothing is booked or charged.</span></p></div>}
      <Suspense fallback={null}><RequestWizard {...props} /></Suspense>
    </div>
  );
}
