import { AirportsHub } from '@/features/airports/route';
import { seoMeta } from '@/features/seo/meta';

export const dynamic = 'force-dynamic';
export async function generateMetadata() { return seoMeta({ title: 'Airport Car Rental, Delivered to the Terminal', description: 'Toronto Pearson and Billy Bishop: the car is brought to the terminal at the standard delivery price. Request with no payment.', path: '/airport-car-rental' }); }
export default function Page() { return <AirportsHub />; }
