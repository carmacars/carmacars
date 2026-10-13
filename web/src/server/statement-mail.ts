import 'server-only';
import { rpc } from '@/lib/db/repo';
import { generatedFile } from '@/server/files';
import type { DocKind } from '@/features/documents/pdf';

// The monthly statement emails (11-statements-and-reports.md section 1; migration 0033): owner statements on
// their payout date (the 10th), investor statements on their Payment Date. For each one due, the PDF is
// rendered and stored first (a final document is stored once), then the database marks it sent and emits
// the email, whose 7-day link the outbox sender signs (app.outbox_file_refs).
const SR = { role: 'service_role' as const };
export interface MailSummary { due: number; sent: number; failed: Array<{ kind: string; key: string; error: string }> }

export async function runStatementMail(deadlineMs = 25_000): Promise<MailSummary> {
  const t0 = Date.now();
  const due = ((await rpc('server_statement_mail_due', {}, SR)) ?? []) as unknown as Array<{ kind: DocKind; key: string }>;
  const out: MailSummary = { due: due.length, sent: 0, failed: [] };
  for (const d of due) {
    if (Date.now() - t0 > deadlineMs) break;
    try {
      const f = await generatedFile(d.kind, d.key);
      if (!f) throw new Error('nothing to render');
      const r = (await rpc('server_statement_mail_release', { p_kind: d.kind, p_key: d.key }, SR)) as unknown as { sent: boolean };
      if (r.sent) out.sent++;
    } catch (e) {
      out.failed.push({ kind: d.kind, key: d.key, error: e instanceof Error ? e.message.slice(0, 200) : 'failed' });
    }
  }
  return out;
}
