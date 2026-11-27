'use server';
import { redirect } from 'next/navigation';
import { renewInterview, TOKEN } from '@/server/interviews';

/** r50 hotfix 2 (5161): the one tap on an expired interview link: a new link, then straight back to the interview. */
export async function renewInterviewAction(form: FormData): Promise<void> {
  const token = String(form.get('token') ?? '');
  if (!TOKEN.test(token)) redirect('/careers');
  await renewInterview(token);
  redirect(`/careers/interview/${token}`);
}
