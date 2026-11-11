import { LocalizedPage, localizedMeta } from '@/features/i18n/route';

// A language version (release 36, part 2): /<lang>/car-rental/[slug]. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ lang: string; slug: string }> };
export async function generateMetadata({ params }: Params) { const p = await params; return localizedMeta(p.lang, 'landing', p.slug); }
export default async function Page({ params }: Params) { const p = await params; return <LocalizedPage code={p.lang} kind="landing" slug={p.slug} />; }
