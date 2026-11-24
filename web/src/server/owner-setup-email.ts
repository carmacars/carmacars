import 'server-only';
import { rpc } from '@/lib/db/repo';
import { auth } from '@/lib/auth';
import { door } from '@/server/door';

// The set-up email of an owner's approved application (moved out of the owner-billing actions in r50 so the Admin
// connector's approve_owner_car sends it too, never callable from a browser).
const SR = { role: 'service_role' as const };

/** After approval: the owner's one email. An owner with no sign-in gets one made now and the link to choose a password
 *  in that same email (nothing is sent by the sign-in service). */
export async function setupEmail(adminId: string, aal: 'aal1' | 'aal2' | null, applicationId: string, setup: { owner_id: string; has_account: boolean; email: string | null; name: string }, resend = false): Promise<string> {
  let passwordUrl: string | null = null;
  if (!setup.has_account && setup.email) {
    const a = await auth();
    if (a.accountLink) {
      const existing = (await rpc('server_user_by_email', { p_email: setup.email }, SR)) as unknown as string | null;
      const made = await a.accountLink(setup.email, setup.name, '/owner/review', existing);
      if (made.ok) {
        await rpc('admin_invite_account', { p_admin: adminId, p: { user_id: made.user.id, email: setup.email, full_name: setup.name, role: 'owner', owner_id: setup.owner_id } }, SR);
        passwordUrl = made.link;
      }
    }
  }
  const r = await door<{ sent: boolean }>(adminId, 'ops_do', 'owner_setup_email', { application_id: applicationId, password_url: passwordUrl, again: resend }, aal);
  return r.sent ? (passwordUrl ? 'The owner was emailed to review and sign, with the link to choose a password.' : 'The owner was emailed to review and sign.') : 'The set-up email was sent before.';
}

