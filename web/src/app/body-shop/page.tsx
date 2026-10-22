import { ServicePage, serviceMeta } from '@/features/places/ServicePage';

// /body-shop (migration 0095): the service page, with its request form and the rental offer.
export const revalidate = 3600;
export async function generateMetadata() { return serviceMeta('bodyshop'); }
export default function Page() { return <ServicePage v="bodyshop" />; }
