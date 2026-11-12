import '@/styles/field.css';
import '@/styles/field-portal.css';
import '@/styles/ui-kit.css';
import type { Metadata, Viewport } from 'next';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { FieldTabs } from '@/features/field-portal/FieldTabs';

// "Add to Home Screen" opens the field work full screen (06-field.md section 1): the manifest and icons.
// No service worker: nothing personal is cached on the phone.
export const metadata: Metadata = {
  manifest: '/staff/field/manifest.webmanifest',
  appleWebApp: { capable: true, title: 'CarmaCars staff', statusBarStyle: 'black' },
  icons: { icon: [{ url: '/staff/field/icon-192.png', sizes: '192x192', type: 'image/png' }], apple: [{ url: '/staff/field/apple-touch-icon.png', sizes: '180x180' }] }
};
export const viewport: Viewport = { themeColor: '#000000' };

// Field work inside the staff portal (0197): the field pages keep their own phone-first column (06-field.md); the staff
// frame around them gives the menu, the guide and Sign out. Every page checks field work itself (requireStaff).
// r35 part X: the four tabs at the thumb (Today, My shifts, My pay, Training; Sales for a person who opted in).
export default async function FieldLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser().catch(() => null);
  const roles = user ? await rolesOf(user.id).catch(() => null) : null;
  return <div className="fd fd--in-staff"><div className="fd__frame">{children}</div>{roles?.field ? <FieldTabs salesOptIn={!!roles.sales_opt_in} /> : null}</div>;
}
