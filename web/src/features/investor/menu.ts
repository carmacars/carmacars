import type { MenuLink, PageTab } from '../portal-nav/tabs.ts';

// The investor portal's menu (r27 portals; r29: Updates): six links. Live sheets are the investor's own model (r27-invsheets);
// Documents holds the statements, the documents to sign and the investor's files on one page; the deck shows while an
// Admin shares it. Nothing here reads the fleet. Pure: InvestorNav and the unit tests read it.
export const INVESTOR_MENU: MenuLink[] = [
  { href: '/investor', label: 'Home', icon: 'home', exact: true },
  { href: '/investor/model', label: 'Live sheets', icon: 'chart', when: 'investor' },
  { href: '/investor/documents', label: 'Documents', icon: 'doc', also: ['/investor/statements', '/investor/sign'] },
  { href: '/investor/updates', label: 'Updates', icon: 'star' },
  { href: '/investor/deck', label: 'Investor deck', icon: 'play', when: 'deck' },
  { href: '/investor/profile', label: 'Account', icon: 'user' }
];

export const INVESTOR_DOCUMENT_TABS: PageTab[] = [
  { key: 'statements', href: '/investor/documents', label: 'Statements' },
  { key: 'sign', href: '/investor/documents?tab=sign', label: 'Documents to sign' },
  { key: 'files', href: '/investor/documents?tab=files', label: 'Your files' }
];

export const INVESTOR_MOVED: Record<string, [string, string | null]> = {
  '/investor/statements': ['/investor/documents', 'statements'],
  '/investor/sign': ['/investor/documents', 'sign']
};
