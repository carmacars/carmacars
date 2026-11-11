import { LocalizedPage, localizedMeta } from '@/features/i18n/route';

// A language hub (release 36, part 2): /<lang>. 404 for a code that is not a language of the site.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ lang: string }> };
export async function generateMetadata({ params }: Params) { return localizedMeta((await params).lang, 'hub'); }
export default async function Page({ params }: Params) { return <LocalizedPage code={(await params).lang} kind="hub" />; }
