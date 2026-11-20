'use server';
import { rpc } from '@/lib/db/repo';

// r48 CM (3110): the restore link of a suspended staff account asks the Admins for access back. The answer is the same
// whether or not the link is good, so the page tells nobody who has an account.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export async function requestStaffRestore(token: string): Promise<{ ok: boolean; message: string }> {
  if (typeof token !== 'string' || !UUID.test(token)) return { ok: false, message: 'This link is not complete. Open it again from the email.' };
  try {
    await rpc('server_staff_restore_request', { p_token: token }, { role: 'service_role' });
    return { ok: true, message: 'Request sent. An Admin approves it, then we email you and you can sign in again.' };
  } catch {
    return { ok: false, message: 'Not sent: the server did not answer. Try again in a minute.' };
  }
}
