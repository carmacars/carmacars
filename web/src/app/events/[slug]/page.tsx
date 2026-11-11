import { EventPage, eventMeta } from '@/features/events/route';

// An event page (release 36, part 5): /events/<slug>. On demand, edge copy only.
export const dynamic = 'force-dynamic';
type Params = { params: Promise<{ slug: string }> };
export async function generateMetadata({ params }: Params) { return eventMeta((await params).slug); }
export default async function Page({ params }: Params) { return <EventPage slug={(await params).slug} />; }
