import '@/styles/portal.css';
import '@/styles/field.css';
import Link from 'next/link';
import type { Metadata, Viewport } from 'next';
import { signOut } from '@/server/actions/auth';
import { currentUser } from '@/server/portal/data';
import { FieldNav } from '@/features/field/FieldNav';

// "Add to Home Screen" opens the field portal full screen (06-field.md section 1): the manifest and icons.
// No service worker: nothing personal is cached on the phone.
export const metadata: Metadata = {
  manifest: '/field/manifest.webmanifest',
  appleWebApp: { capable: true, title: 'CarmaCars field', statusBarStyle: 'black' },
  icons: { icon: [{ url: '/field/icon-192.png', sizes: '192x192', type: 'image/png' }], apple: [{ url: '/field/apple-touch-icon.png', sizes: '180x180' }] }
};
export const viewport: Viewport = { themeColor: '#000000' };

// The field portal's frame (06-field.md): one column, phone first; every page checks the role itself.
export default async function FieldLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  return (
    <div className="fd">
      <div className="fd__frame">
        <header className="fd__top"><Link prefetch={false} className="link" href="/field"><b>CarmaCars field</b></Link>
          {user && <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form>}</header>
        {user && <FieldNav />}
        <main>{children}</main>
      </div>
    </div>
  );
}
