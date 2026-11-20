'use server';
import { redirect } from 'next/navigation';
import { salesYes } from '@/server/sales-yes';

/** One press: the Sales application and the AI interview link; then straight to the interview. */
export async function salesYesAction(form: FormData): Promise<void> {
  const token = String(form.get('token') ?? '');
  let url: string | null = null;
  try { url = (await salesYes(token)).interview_url; } catch (e) {
    redirect(`/careers/sales-yes/${encodeURIComponent(token)}?error=${encodeURIComponent((e instanceof Error ? e.message : String(e)).replace(/^.*?ERROR:\s*/, '').slice(0, 160))}`);
  }
  redirect(url ? new URL(url).pathname : `/careers/sales-yes/${encodeURIComponent(token)}?sent=1`);
}
