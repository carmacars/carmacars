import '@/styles/portal.css';
import '@/styles/field.css';
import Link from 'next/link';
import { signOut } from '@/server/actions/auth';
import { currentUser } from '@/server/portal/data';

// The field portal's frame (06-field.md): one column, phone first; every page checks the role itself.
export default async function FieldLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  return (
    <div className="fd">
      <div className="fd__frame">
        <header className="fd__top"><Link prefetch={false} className="link" href="/field"><b>CarmaCars field</b></Link>
          {user && <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form>}</header>
        <main>{children}</main>
      </div>
    </div>
  );
}
