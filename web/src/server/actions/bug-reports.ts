'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// Release 37 (2340): an Admin triages a bug report (status, a note, the release that fixed it). The database checks the
// Admin role (app.bug_report_update) and the audit log keeps the change.
export async function updateBugReport(id: string, form: FormData): Promise<void> {
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(`/admin/bug-reports/${id}`)}`);
  const s = (k: string) => { const v = form.get(k); return typeof v === 'string' && v.trim() ? v.trim() : undefined; };
  let err = '';
  try {
    await door(user.id, 'ops_do', 'bug_report_update', { id, status: s('status'), note: s('note'), fixed_in: s('fixed_in') }, await sessionAal());
  } catch (e) { err = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not saved.'; }
  revalidatePath('/admin/bug-reports');
  redirect(`/admin/bug-reports/${id}${err ? `?error=${encodeURIComponent(err.slice(0, 200))}` : '?saved=1'}`);
}
