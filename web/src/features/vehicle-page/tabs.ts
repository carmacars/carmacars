// r31: the vehicle page's tabs, the same for Admin and staff (each viewer sees the tabs its function uses), and the old
// hash links (#maintenance from task links and bookmarks) mapped to the tab that holds that part now. Pure.
import type { VehicleCan } from '../shared-pages/viewer.ts';

export type VehicleTab = 'overview' | 'rates' | 'calendar' | 'listing' | 'maintenance' | 'records';
const ALL: ReadonlyArray<readonly [VehicleTab, string]> = [['overview', 'Overview'], ['rates', 'Rates & fees'], ['calendar', 'Calendar'], ['listing', 'Listing'], ['maintenance', 'Maintenance'], ['records', 'Owner & documents']];

export function vehicleTabs(c: VehicleCan): Array<readonly [VehicleTab, string]> {
  if (c.admin) return [...ALL];
  if (c.maintenanceOnly) return [['maintenance', 'Maintenance']];
  return ALL.filter(([k]) => k === 'overview' || k === 'listing' || (k === 'rates' && c.rates) || (k === 'maintenance' && c.maintenance) || k === 'records')
    .map(([k, l]) => (k === 'records' ? [k, 'Documents'] as const : [k, l] as const));
}

/** The tab open: ?tab= (an old ?tab=fees opens Rates & fees); without one, ?record=1 (the record pop-up) opens Maintenance. */
export function vehicleTab(tabs: ReadonlyArray<readonly [VehicleTab, string]>, tab: string | undefined, record: string | undefined): VehicleTab {
  const t = tab === 'fees' ? 'rates' : tab;
  const keys = tabs.map(([k]) => k);
  if (t && keys.includes(t as VehicleTab)) return t as VehicleTab;
  if (!t && record === '1' && keys.includes('maintenance')) return 'maintenance';
  return keys[0]!;
}

export const HASH_TAB: Record<string, VehicleTab> = { maintenance: 'maintenance', rates: 'rates', fees: 'rates', listing: 'listing', documents: 'records', records: 'records', calendar: 'calendar' };

export function tabForHash(hash: string, tabs: readonly string[]): VehicleTab | null {
  const t = HASH_TAB[hash.replace(/^#/, '')];
  return t && tabs.includes(t) ? t : null;
}
