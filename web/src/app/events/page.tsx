import { EventsHub } from '@/features/events/route';
import { seoMeta } from '@/features/seo/meta';

// The events hub (release 36, part 5).
export const dynamic = 'force-dynamic';
export async function generateMetadata() { return seoMeta({ title: 'Rent a Car for Toronto Events', description: 'Festivals, games, concerts and shows in Toronto and the GTA: rent a car, delivered or picked up in Toronto. Request with no payment.', path: '/events' }); }
export default function Page() { return <EventsHub />; }
