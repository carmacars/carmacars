import { RentVsOwnHub } from '@/features/rent-vs-own/route';
import { seoMeta } from '@/features/seo/meta';

export const dynamic = 'force-dynamic';
export async function generateMetadata() { return seoMeta({ title: 'Renting vs Owning a Car in Toronto', description: 'The monthly cost of owning a popular model, line by line with sources, against renting by the month from CarmaCars.', path: '/rent-vs-own' }); }
export default function Page() { return <RentVsOwnHub />; }
