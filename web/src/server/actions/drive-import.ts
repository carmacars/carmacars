'use server';
import { revalidatePath } from 'next/cache';
import { DbError } from '@/lib/db/repo';
import type { ActionResult } from '@/features/forms/schemas';
import { currentUser } from '@/server/portal/data';
import { door, sessionAal } from '@/server/door';
import { kickDriveImport } from '@/server/drive-import';
import { parseDriveLink } from '@/features/drive-import/drive-folder';
import type { ImportView, RunRow, CarOption } from '@/features/drive-import/types';

// Import photos from a Google Drive link (migration 0760), through the staff door's ops calls: the same for an Admin and for
// Fleet and customer service staff; the database decides who may (app.drive_import_may) and does the work in steps of the
// Worker (src/server/drive-import.ts). Starting, confirming and trying again start a step right after the response.
type R<T = unknown> = ActionResult<T>;
const fail = (e: unknown): R<never> => ({ ok: false, code: 'refused', message: e instanceof DbError || e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'Something went wrong.' });
async function me() {
  const user = await currentUser();
  if (!user) throw new Error('Sign in first.');
  return { user, aal: await sessionAal() };
}

/** `vehicleId`: this car's photos; empty: a whole folder tree, matched to cars on the next screen. */
export async function driveImportStart(link: string, vehicleId: string | null, submit: boolean): Promise<R<{ id: string; status: string; existing: boolean }>> {
  try {
    const parsed = parseDriveLink(link);
    if (!parsed || parsed.kind !== 'folder') return { ok: false, code: 'invalid', message: 'Paste the link of a Google Drive folder (drive.google.com/drive/folders/...).' };
    const { user, aal } = await me();
    const data = await door<{ id: string; status: string; existing: boolean }>(user.id, 'ops_do', 'drive_import_start',
      { root_id: parsed.id, root_url: `https://drive.google.com/drive/folders/${parsed.id}`, vehicle_id: vehicleId || null, submit }, aal);
    kickDriveImport();
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function driveImportGet(id: string): Promise<R<ImportView>> {
  try {
    const { user, aal } = await me();
    const data = await door<ImportView>(user.id, 'ops_read', 'drive_import_get', { import: id }, aal);
    // a run with work that no step holds (a lost step): start one
    if (data.import.due) kickDriveImport();
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function driveImportList(vehicleId: string | null): Promise<R<RunRow[]>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<RunRow[]>(user.id, 'ops_read', 'drive_import_list', { vehicle: vehicleId || null }, aal) };
  } catch (e) { return fail(e); }
}

export async function driveImportCars(): Promise<R<CarOption[]>> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door<CarOption[]>(user.id, 'ops_read', 'drive_import_cars', {}, aal) };
  } catch (e) { return fail(e); }
}

export async function driveImportConfirm(id: string, rows: Array<{ folder: string; vehicle: string | null; include: boolean }>, submit: boolean): Promise<R<{ folders: number; photos: number }>> {
  try {
    const { user, aal } = await me();
    const data = await door<{ folders: number; photos: number }>(user.id, 'ops_do', 'drive_import_confirm', { import: id, rows, submit }, aal);
    kickDriveImport();
    return { ok: true, data };
  } catch (e) { return fail(e); }
}

export async function driveImportCancel(id: string): Promise<R> {
  try {
    const { user, aal } = await me();
    return { ok: true, data: await door(user.id, 'ops_do', 'drive_import_cancel', { import: id }, aal) };
  } catch (e) { return fail(e); }
}

export async function driveImportRetry(id: string, refresh: string[] = []): Promise<R> {
  try {
    const { user, aal } = await me();
    const data = await door(user.id, 'ops_do', 'drive_import_retry', { import: id }, aal);
    kickDriveImport();
    for (const x of refresh) revalidatePath(x);
    return { ok: true, data };
  } catch (e) { return fail(e); }
}
