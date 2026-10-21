import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { SignalSettings } from '@/features/live/SignalSettings';
import type { SignalSettingsData } from '@/features/live/staff';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Signal settings', path: '/admin/live/signals', noindex: true, description: 'The signals of Live visitors: points, thresholds, suggested actions and messages.' });

// Today > Live visitors > Signal settings (migration 0086).
export default async function LiveSignals() {
  const { read } = await page('/admin/live/signals');
  const d = await read<SignalSettingsData>('live_signal_rules');
  return (<><PageHead title="Signal settings" kicker="Live visitors" /><SignalSettings initial={d} /></>);
}
