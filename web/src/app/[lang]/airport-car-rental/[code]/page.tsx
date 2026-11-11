import { LocalizedPage, localizedMeta } from '@/features/i18n/route';

// A language version (release 36, part 2): /<lang>/airport-car-rental/[code]. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ lang: string; code: string }> };
export async function generateMetadata({ params }: Params) { const p = await params; return localizedMeta(p.lang, 'airport', p.code); }
export default async function Page({ params }: Params) { const p = await params; return <LocalizedPage code={p.lang} kind="airport" slug={p.code} />; }
