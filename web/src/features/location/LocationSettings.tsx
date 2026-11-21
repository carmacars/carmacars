import 'server-only';
import { door } from '@/server/door';
import { viewAs } from '@/server/view-as';
import type { MyLocation } from '@/features/live-map/people';
import { LocationCard } from './LocationCard';

// The settings card's server half (migration 3350): this person's own state (ops_read my_location). Nothing while an
// Admin views a portal as someone else, nor for a person the live map never shows.
export async function LocationSettings({ userId, className }: { userId: string; className?: string }) {
  if (await viewAs().catch(() => null)) return null;
  const s = await door<MyLocation>(userId, 'ops_read', 'my_location').catch(() => null);
  if (!s?.kind) return null;
  return <LocationCard initial={s} className={className} />;
}
