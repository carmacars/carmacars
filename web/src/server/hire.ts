import 'server-only';
import { door } from '@/server/door';
import { inviteAs } from '@/server/invite';
import { prepareGenerated, sendGenerated } from '@/server/person-agreements';
import { missingRequired } from '@/features/person-agreements/model';
import { HIRE_FUNCTIONS, agreementValues, inviteFor, type HireFunction, type HireStatus } from '@/features/careers/hire';

// One-step Hire (release 33, migration 0730): one confirm, as this Admin, does the whole onboarding. The sign-in and its
// invitation here (the auth server is reached from the web layer), then app.hire_onboard in one database transaction (the
// profile, hired, the interview items closed, the welcome email with the pay details link, the academy with the gate on,
// the first-day To do's), then the staff agreement generated and sent to sign (or what it waits for). The Admin screen and
// the Claude connector (hire_applicant, after its preview) both call it, with the session's assurance level (the connector's
// key counts as the Admin's second factor, aal2, as in 0562).
export interface HireInput { id: string; function?: string | null; start_on?: string | null; pay_cents?: number | null; pay_currency?: string | null }
type Aal = 'aal1' | 'aal2' | null;
type App = { application: { email: string | null; full_name: string; status: string }; role: { staff_kind: 'field' | 'va'; va_function: string | null; cover_functions: string[]; work_mode: 'in_person' | 'remote' | null } };

export async function oneStepHire(adminId: string, aal: Aal, i: HireInput): Promise<{ ok: true; status: HireStatus } | { ok: false; message: string }> {
  if (!/^[0-9a-f-]{36}$/i.test(i.id ?? '')) return { ok: false, message: 'Choose a candidate.' };
  const fn = (i.function ?? '') as HireFunction | '';
  if (fn && !HIRE_FUNCTIONS.includes(fn)) return { ok: false, message: 'Choose the role: customer service, fleet, finance, sales in person, sales remote or field.' };
  const a = await door<App>(adminId, 'admin_read', 'hiring_application', { id: i.id }, aal);
  if (!a.application.email) return { ok: false, message: 'This application has no email address.' };
  const preview = await door<{ function: HireFunction }>(adminId, 'admin_read', 'hire_preview', { id: i.id, function: fn || null }, aal);
  const chosen = preview.function;
  // 1. the sign-in and the invitation, with the function chosen
  const inv = await inviteAs(adminId, { email: a.application.email, full_name: a.application.full_name, ...inviteFor(chosen, a.role.cover_functions ?? []) });
  if (!inv.ok) return { ok: false, message: inv.message };
  // 2. everything in the database
  let status = await door<HireStatus>(adminId, 'admin_do', 'hire_onboard', { id: i.id, user_id: inv.data.user_id, function: chosen, start_on: i.start_on || null,
    pay_cents: i.pay_cents ?? null, pay_currency: i.pay_currency || null }, aal);
  // 3. the agreement, unless it was sent already
  const step = status.steps?.find((s) => s.key === 'agreement');
  if (step && step.state === 'todo') status = await sendHireAgreement(adminId, aal, i.id, inv.data.user_id, status);
  return { ok: true, status };
}

/** Generate the staff agreement from the record, the role, the pay and the start date, and send it to sign; when a value only
 *  the hire can give is missing (a field hire's home address and licence number), record what it waits for. */
export async function sendHireAgreement(adminId: string, aal: Aal, applicationId: string, userId: string, status?: HireStatus): Promise<HireStatus> {
  try {
    const prep = await prepareGenerated(adminId, aal, 'staff_agreement', userId);
    const values = agreementValues(prep.fields, status ?? null);
    const missing = missingRequired(prep.fields, values);
    if (missing.length) return await door<HireStatus>(adminId, 'admin_do', 'hire_agreement_record', { id: applicationId, missing }, aal);
    const r = await sendGenerated(adminId, aal, 'staff_agreement', userId, values, { category: '', paragraph: '' });
    return await door<HireStatus>(adminId, 'admin_do', 'hire_agreement_record', { id: applicationId, request_id: r.id, missing: [] }, aal);
  } catch (e) {
    const error = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The agreement could not be sent';
    return door<HireStatus>(adminId, 'admin_do', 'hire_agreement_record', { id: applicationId, missing: [], error }, aal);
  }
}
