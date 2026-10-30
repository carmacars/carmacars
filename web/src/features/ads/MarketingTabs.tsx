import { Tabs } from '@/features/admin/ui';

// Admin > Marketing (migration 0167): one row of tabs across its pages.
export const MARKETING: Array<[string, string]> = [['/admin/marketing/listings', 'Listings'], ['/admin/marketing/ads', 'Posted ads'], ['/admin/marketing/social', 'Social drafts'], ['/admin/marketing/channels', 'Listing channels'],
  ['/admin/marketing/report', 'Bookings by channel'], ['/admin/marketing/recruit', 'Owner recruitment'], ['/admin/marketing/owner-pipeline', 'Owner pipeline']];
export function MarketingTabs({ current, counts = {} }: { current: string; counts?: Record<string, number> }) {
  return <Tabs label="Marketing" current={current} items={MARKETING.map(([h, l]) => [h, l, counts[h]] as [string, string, number?])} />;
}
