'use client';
import { PortalMenu } from '@/features/portal-nav/PortalMenu';
import { OWNER_MENU } from './menu';

// The owner portal's menu (r27 portals: six tabs with chips became five links; Money and Account are one page each with
// tabs). A partner rental company (0046) uses the same menu (features/owner/menu.ts).
export function OwnerNav({ unread, partner = false }: { unread: number; partner?: boolean }) {
  return <PortalMenu menu={OWNER_MENU} label={partner ? 'Partner portal' : 'Owner portal'} unread={unread} testId="owner-nav" />;
}
