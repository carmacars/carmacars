import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';

// The person the owner application is for. A staff member or the Admin signed in on this device is filling it in for an
// owner (in person, on their phone or laptop), so the session is not the applicant: the form starts blank and editable,
// asks the owner's own email and password, and the account it creates is the owner's (never the staff account's).
export async function applicantUser() {
  const user = await currentUser();
  if (!user) return null;
  const r = await rolesOf(user.id).catch(() => null);
  if (r && (r.admin || r.va || r.field)) return null;
  return user;
}
