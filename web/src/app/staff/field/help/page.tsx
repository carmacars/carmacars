import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { HelpSearch } from '@/features/field-portal/RenterHelp';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Help a renter', path: '/staff/field/help', noindex: true, description: 'Find a booking to help the renter on the spot.' });

// Help a renter on the spot (r35 part X): find any current booking by its number, the renter's name or phone (each search is logged).
export default async function HelpFind() {
  await requireStaff('field', '/staff/field/help');
  return (
    <>
      <header className="fp-hello"><h1>Help a renter</h1><p>Payment, deposit, licence, signature</p></header>
      <HelpSearch />
    </>
  );
}
