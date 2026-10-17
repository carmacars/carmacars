'use server';
import { revalidatePath } from 'next/cache';
import { DbError, rpc } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';

// The owner applications inbox (migration 0054): checks, notes, ask for something, approve, decline; and the owner's
// answer from the owner portal. The database checks every one again.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}
const refresh = (id: string) => { revalidatePath('/admin/applications'); revalidatePath(`/admin/applications/${id}`); revalidatePath('/admin'); };

async function act(name: string, id: string, p: Record<string, unknown>): Promise<R<Record<string, unknown>>> {
  try {
    const { user, aal } = await me();
    const r = await door<Record<string, unknown>>(user.id, 'ops_do', name, { id, ...p }, aal);
    refresh(id);
    return { ok: true, data: r };
  } catch (e) { return fail(e); }
}

export async function applicationCheck(id: string, check: string, status: string, note: string) { return act('application_check', id, { check, status, note }); }
export async function applicationNote(id: string, body: string): Promise<R<Record<string, unknown>>> {
  if (!body.trim()) return { ok: false, code: 'invalid', message: 'Write the note.', fieldErrors: { body: 'Write the note.' } };
  return act('application_note', id, { body });
}
export async function applicationRequest(id: string, items: string[], message: string): Promise<R<Record<string, unknown>>> {
  if (!items.length) return { ok: false, code: 'invalid', message: 'Choose what to ask for.', fieldErrors: { items: 'Choose at least one item.' } };
  return act('application_request', id, { items, message });
}
export async function applicationDecline(id: string, reason: string): Promise<R<Record<string, unknown>>> {
  if (!reason.trim()) return { ok: false, code: 'invalid', message: 'Give the reason the owner reads.', fieldErrors: { reason: 'Give the reason the owner reads.' } };
  return act('application_decline', id, { reason });
}
export async function applicationApprove(id: string) { return act('application_approve', id, {}); }

/** The owner answers what staff asked for, from the owner portal. */
export async function answerApplication(id: string, reply: string): Promise<R<null>> {
  if (!reply.trim()) return { ok: false, code: 'invalid', message: 'Write your answer.', fieldErrors: { reply: 'Write your answer, or say where you uploaded the documents.' } };
  try {
    const user = await currentUser();
    if (!user) throw new Error('Sign in first.');
    await rpc('server_application_owner_reply', { p_by: user.id, p: { id, reply: reply.trim() } }, { role: 'service_role' });
    revalidatePath('/owner');
    return { ok: true, data: null };
  } catch (e) { return fail(e); }
}
