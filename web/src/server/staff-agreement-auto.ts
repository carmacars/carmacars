import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { prepareGenerated, sendGenerated } from '@/server/person-agreements';
import { missingRequired } from '@/features/person-agreements/model';
import { agreementValues } from '@/features/careers/hire';

// Every staff member without a signed staff agreement gets theirs by itself (migration 1060): the right agreement for their
// function, filled from their record and their hire's pay and start date, sent to sign in their portal. Run by the agreements
// job (the Worker's cron, when server_jobs_due says agreements), as the Admin the automatic work acts as. A value only the
// person or an Admin can give (a field hire's licence number) is recorded as missing and raises an Admin To do.
const SR = { role: 'service_role' as const };
type Due = { actor: string | null; users: Array<{ user_id: string; pay: { pay_basis: string | null; pay_cents: number | null; pay_currency: string | null } | null }> };

export async function runStaffAgreements(max = 2): Promise<{ sent: number; waiting: number; failed: number }> {
  const due = (await rpc('server_staff_agreements_due', { p_limit: max }, SR)) as unknown as Due;
  let sent = 0; let waiting = 0; let failed = 0;
  if (!due?.actor) return { sent, waiting, failed };
  for (const u of due.users ?? []) {
    try {
      const prep = await prepareGenerated(due.actor, 'aal2', 'staff_agreement', u.user_id);
      const values = agreementValues(prep.fields, u.pay?.pay_basis ? { pay_basis: u.pay.pay_basis as 'monthly', pay_cents: u.pay.pay_cents ?? 0, pay_currency: u.pay.pay_currency ?? '' } : null);
      const missing = missingRequired(prep.fields, values);
      if (missing.length) { await rpc('server_staff_agreement_auto_done', { p_user: u.user_id, p: { missing } as unknown as Json }, SR); waiting++; continue; }
      const r = await sendGenerated(due.actor, 'aal2', 'staff_agreement', u.user_id, values, { category: '', paragraph: '' });
      await rpc('server_staff_agreement_auto_done', { p_user: u.user_id, p: { request_id: r.id } as unknown as Json }, SR);
      sent++;
    } catch (e) {
      await rpc('server_staff_agreement_auto_done', { p_user: u.user_id, p: { error: e instanceof Error ? e.message.slice(0, 300) : 'failed' } as unknown as Json }, SR).catch(() => undefined);
      failed++;
    }
  }
  return { sent, waiting, failed };
}
