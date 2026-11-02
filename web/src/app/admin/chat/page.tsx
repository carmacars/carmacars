import { redirect } from 'next/navigation';
import { requireAdmin } from '@/server/admin/data';
import { chatMovedTo } from '@/features/visitors/tabs';

export const dynamic = 'force-dynamic';

// Bookings > Live chat (migration 0060), with Texts and calls (0085), is the Visitors page's Chat tab since the r27
// consolidation. Old links (alerts, emails, bookmarks) land there with their query kept (?id= opens the conversation,
// ?view=phone the Texts and calls inbox); the gate is the same (Admins), checked before the move.
export default async function Chat({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [, sp] = await Promise.all([requireAdmin('/admin/visitors?view=chat'), searchParams]);
  redirect(chatMovedTo('admin', sp));
}
