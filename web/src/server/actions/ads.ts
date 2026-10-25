'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { door } from '@/server/door';
import { assertAdmin } from '@/server/admin/data';
import { mondayOf, weekPlan, type Facts } from '@/features/ads/social';

// Admin > Marketing > Social drafts (migration 0167): "Write this week's drafts" runs the same generator as the ads job for
// the week shown (from today on), now. A day already drafted is left alone.
export async function writeWeekDrafts(fd: FormData): Promise<void> {
  const admin = await assertAdmin();
  const week = String(fd.get('week') ?? '');
  const facts = await door<Facts>(admin.id, 'admin_read', 'ads_listings', {});
  const monday = mondayOf(/^\d{4}-\d{2}-\d{2}$/.test(week) ? week : facts.today);
  const drafts = weekPlan(facts, monday);
  const r = drafts.length ? await door<{ added: number }>(admin.id, 'admin_do', 'social_drafts_put', { drafts }) : { added: 0 };
  revalidatePath('/admin/marketing/social');
  redirect(`/admin/marketing/social?week=${monday}&added=${r.added}`);
}
