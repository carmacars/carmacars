'use server';
import { redirect } from 'next/navigation';
import { endPending } from '@/server/capture';

/** "This is not me" / "Forget this device": this browser leaves its unverified session (migration 0090). */
export async function leavePending(): Promise<void> {
  await endPending();
  redirect('/');
}
