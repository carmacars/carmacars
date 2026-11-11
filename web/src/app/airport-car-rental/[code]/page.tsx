import { AirportRoute, airportMeta } from '@/features/airports/route';

// An airport page (release 36, part 10): /airport-car-rental/<code>. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ code: string }> };
export async function generateMetadata({ params }: Params) { return airportMeta((await params).code); }
export default async function Page({ params }: Params) { return <AirportRoute code={(await params).code} />; }
