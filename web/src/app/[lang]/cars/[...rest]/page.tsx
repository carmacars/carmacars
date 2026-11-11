import { LocalizedPage, localizedMeta } from '@/features/i18n/route';

// A language version of a vehicle page (release 37, migration 2302): /<lang>/cars/<make>/<model>/<year>/<trim>[/<place>[/<colour>]],
// only where a real car on the site backs it. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ lang: string; rest: string[] }> };
const path = (rest: string[]) => `/cars/${rest.join('/')}`;
export async function generateMetadata({ params }: Params) { const p = await params; return localizedMeta(p.lang, 'vehicle', path(p.rest)); }
export default async function Page({ params }: Params) { const p = await params; return <LocalizedPage code={p.lang} kind="vehicle" slug={path(p.rest)} />; }
