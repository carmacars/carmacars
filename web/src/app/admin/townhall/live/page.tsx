import { redirect } from 'next/navigation';

export const dynamic = 'force-dynamic';

// r50 (5000): the Admin's townhall call; until the in-site call (release 50, part 2), the townhall page.
export default function AdminTownhallLive() {
  redirect('/admin/townhall');
}
