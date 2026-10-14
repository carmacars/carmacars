'use server';
import { redirect } from 'next/navigation';
import { rpc } from '@/lib/db/repo';

// One-click unsubscribe from marketing emails (0018 app.unsubscribe through 0034's wrapper). The page's
// button posts here; mail apps post to /api/unsubscribe (List-Unsubscribe-Post). Idempotent.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function unsubscribe(form: FormData): Promise<void> {
  const token = String(form.get('token') ?? '');
  if (!UUID.test(token)) redirect('/unsubscribe');
  await rpc('server_unsubscribe', { p_token: token }, { role: 'service_role' });
  redirect(`/unsubscribe?token=${encodeURIComponent(token)}&done=1`);
}
