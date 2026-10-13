import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { BulkRates } from '@/features/admin/BulkRates';
import { PageHead } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Bulk rate change', path: '/admin/vehicles/bulk-rates', noindex: true, description: 'Change rates for many cars at once.' });

// Bulk rate change with a preview (preview_bulk_rate_change, then apply_bulk_rate_change).
export default async function BulkRatesPage() {
  const { list } = await page('/admin/vehicles/bulk-rates');
  const [classes, owners] = await Promise.all([list<{ code: string; label: string }>('vehicle_classes', { order: 'sort_order', asc: true }), list<{ id: string; legal_name: string }>('owners', { order: 'legal_name', asc: true, limit: 500 })]);
  return (<><PageHead title="Bulk rate change" kicker="Preview first; Self-Managed cars are skipped (their Owners set rates)" /><BulkRates classes={classes.rows} owners={owners.rows} /></>);
}
