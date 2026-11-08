'use server';
import { revalidatePath } from 'next/cache';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// Welcome (0802): a new hire ticks off one of their own first-day To do's. The database checks it is theirs.
export async function welcomeTaskDone(id: string): Promise<{ ok: boolean; message?: string }> {
  const user = await currentUser();
  if (!user) return { ok: false, message: 'Sign in first.' };
  try {
    await door(user.id, 'ops_do', 'staff_welcome_task', { id }, await sessionAal());
    revalidatePath('/staff/welcome');
    return { ok: true };
  } catch (e) { return { ok: false, message: e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Not saved.' }; }
}
