'use client';
import { PortalMenu } from '@/features/portal-nav/PortalMenu';
import { RENTER_MENU } from './menu';

// The renter portal's menu (r27 portals): Trips, Documents, Rewards, Account (features/portal/menu.ts).
export function PortalNav({ unread }: { unread: number }) {
  return <PortalMenu menu={RENTER_MENU} label="Your account" unread={unread} testId="renter-nav" />;
}
