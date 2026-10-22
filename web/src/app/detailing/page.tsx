import { ServicePage, serviceMeta } from '@/features/places/ServicePage';

// /detailing (migration 0095): the service page, with its request form and the rental offer.
export const revalidate = 3600;
export async function generateMetadata() { return serviceMeta('detailing'); }
export default function Page() { return <ServicePage v="detailing" />; }
