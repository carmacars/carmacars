import 'server-only';
import { door } from '@/server/door';
import type { PayIdRow, SpendRow } from '@/features/field-portal/FinancePanels';

/** Finance's field spending (with a 5-minute link to each receipt) and the field staff's pay details (r35 part X). */
export async function fieldFinance(userId: string, aal?: 'aal1' | 'aal2' | null, va?: string): Promise<{ spends: SpendRow[]; ids: PayIdRow[] }> {
  const extra = va ? { _va: va } : {};
  const [rows, ids] = await Promise.all([door<Array<SpendRow & { receipt_path: string | null }>>(userId, 'ops_read', 'field_spends', extra, aal).catch(() => []),
    door<PayIdRow[]>(userId, 'ops_read', 'pay_identity_list', extra, aal).catch(() => [] as PayIdRow[])]);
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  const spends = await Promise.all(rows.map(async ({ receipt_path, ...r }) => ({ ...r, receipt_url: receipt_path ? await s.signedDownloadUrl('documents', receipt_path, 300).catch(() => null) : null })));
  return { spends, ids };
}
