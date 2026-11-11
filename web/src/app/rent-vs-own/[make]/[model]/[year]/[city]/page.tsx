import { RentVsOwn, rvoMeta } from '@/features/rent-vs-own/route';

// Renting vs owning a model year in a city (release 36, part 11). On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ make: string; model: string; year: string; city: string }> };
export async function generateMetadata({ params }: Params) { const p = await params; return rvoMeta(p.make, p.model, p.year, p.city); }
export default async function Page({ params }: Params) { const p = await params; return <RentVsOwn make={p.make} model={p.model} year={p.year} city={p.city} />; }
