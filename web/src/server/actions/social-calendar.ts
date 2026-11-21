'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { monthPlan, regeneratePost, type Learned, type Plan } from '@/features/social/calendar';
import type { Facts } from '@/features/ads/social';

// The content calendar's two written steps (release 48, migration 3263): write a month now (the ads job writes it by
// itself; this is the button for "now"), and write one post again (Regenerate). The words come from the same writer
// (src/features/social/calendar.ts) with the fleet's facts read through the door, as Marketing; the database stores a
// post as a draft and never overwrites a slot a person already handled. Approve, edit and reject go through the door's
// actions (social_cal_decide, social_cal_save).
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not done. Please try again.' });
const PATHS = ['/admin/marketing/calendar', '/staff/marketing/calendar'];
interface Job { facts: Facts; job: { enabled: boolean; months: string[]; plan: Plan; learned: Learned; recent: string[] } }
interface CalPost { id: string; slot_no: number; regenerated: number; status: string }

async function me() {
  const user = await currentUser();
  if (!user) throw new DbError('Sign in first.', '42501');
  return { user, aal: await sessionAal() };
}

export async function writeCalendarMonth(month: string): Promise<R<{ added: number }>> {
  try {
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) return { ok: false, code: 'invalid', message: 'Choose a month.' };
    const { user, aal } = await me();
    const j = await door<Job>(user.id, 'ops_read', 'social_calendar_facts', {}, aal);
    const cal = monthPlan(j.facts, month, j.job.plan, j.job.learned, { recent: j.job.recent });
    if (!cal.posts.length) return { ok: false, code: 'empty', message: 'There is nothing to write for that month: its days have passed, or no car is listed with photos yet.' };
    // the database reads the month as a date (app.social_cal_store): its first day, not "2026-11" (which it refused)
    const r = await door<{ added: number }>(user.id, 'ops_do', 'social_cal_put', { ...cal, month: `${month}-01` } as unknown as Record<string, unknown>, aal);
    for (const p of PATHS) revalidatePath(p);
    return { ok: true, data: { added: Number(r.added) || 0 } };
  } catch (e) { return fail(e); }
}

export async function regenerateCalendarPost(month: string, id: string): Promise<R<{ id: string }>> {
  try {
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month) || !/^[0-9a-f-]{36}$/.test(id)) return { ok: false, code: 'invalid', message: 'Unknown post.' };
    const { user, aal } = await me();
    const [j, cal] = await Promise.all([door<Job>(user.id, 'ops_read', 'social_calendar_facts', {}, aal), door<{ posts: CalPost[] }>(user.id, 'ops_read', 'social_calendar', { month }, aal)]);
    const post = cal.posts.find((p) => p.id === id);
    if (!post) return { ok: false, code: 'missing', message: 'This post is no longer on the calendar.' };
    if (!['draft', 'rejected'].includes(post.status)) return { ok: false, code: 'refused', message: 'Take the approval back first: an approved post is already scheduled.' };
    const again = regeneratePost(j.facts, month, j.job.plan, j.job.learned, post.slot_no, (post.regenerated ?? 0) + 1, { recent: j.job.recent });
    if (!again) return { ok: false, code: 'empty', message: 'There is nothing else to write for this day yet.' };
    await door(user.id, 'ops_do', 'social_cal_save', { id, regenerated: true, caption: again.caption, hook: again.hook, hashtags: again.hashtags, music: again.music ?? '',
      vehicle_id: again.vehicle_id ?? '', photos: again.photos, link: again.link ?? '', shot_list: again.shot_list ?? '' }, aal);
    for (const p of PATHS) revalidatePath(p);
    return { ok: true, data: { id } };
  } catch (e) { return fail(e); }
}
