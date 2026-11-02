'use client';
import { PortalMenu } from '@/features/portal-nav/PortalMenu';
import { INVESTOR_MENU } from './menu';

// The investor portal's menu (r27 portals): Home, Live sheets, Documents, the deck while an Admin shares it, Account
// (features/investor/menu.ts).
export function InvestorNav({ deck, investor }: { deck: boolean; investor: boolean }) {
  return <PortalMenu menu={INVESTOR_MENU} label="Investor portal" flags={{ deck, investor }} testId="investor-nav" />;
}
