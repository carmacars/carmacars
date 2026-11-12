import { LocalizedPage, localizedMeta } from '@/features/i18n/route';

// A language version of a per-car service page (release 37, migration 2302): /<lang>/t/<term>/<make>/<model>/<year>/<trim>
// (detailing, and the DUI or suspension rentals the terms serve), only where a real car on the site backs it. Edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ lang: string; seg: string[] }> };
const path = (seg: string[]) => `/t/${seg.join('/')}`;
export async function generateMetadata({ params }: Params) { const p = await params; return localizedMeta(p.lang, 'vehicle', path(p.seg)); }
export default async function Page({ params }: Params) { const p = await params; return <LocalizedPage code={p.lang} kind="vehicle" slug={path(p.seg)} />; }
