import { door } from '@/server/door';
import { HomeAddressForm } from './HomeAddressForm';

// The staff member's home address (migration 0059). Read through the staff door; an Admin can still edit it on the staff
// member's Sales page.
export interface HomeAddressState { home_address: string | null; home_postal_code: string | null; missing: boolean }
const WHY = 'We need it before you add a rental or earn a commission: a rental by someone at your own address earns no commission. Only Admins see it.';

export async function homeAddressOf(userId: string, portal: 'va' | 'field'): Promise<HomeAddressState> {
  try {
    const r = await door<Partial<HomeAddressState>>(userId, portal === 'va' ? 'va_read' : 'field_read', 'home_address', {});
    return { home_address: r.home_address ?? null, home_postal_code: r.home_postal_code ?? null, missing: !!r.missing };
  } catch { return { home_address: null, home_postal_code: null, missing: false }; }
}

/** The card at the top of every page until the address is in (the first sign-in), and in front of Add a rental and signing. */
export function HomeAddressCard({ portal, title = 'Welcome. First, your home address', intro, testId = 'home-address-card' }: { portal: 'va' | 'field'; title?: string; intro?: string; testId?: string }) {
  return (
    <section className={portal === 'field' ? 'fd-card stack' : 'pt-card stack'} aria-labelledby={`${testId}-t`} data-testid={testId} style={{ marginBottom: 'var(--s-4)' }}>
      <h2 className="d4" id={`${testId}-t`}>{title}</h2>
      <p className="small">{intro ?? WHY}</p>
      <HomeAddressForm portal={portal} />
    </section>
  );
}

/** The profile's section: the address as saved, and the form to change it. */
export function HomeAddressSection({ portal, state }: { portal: 'va' | 'field'; state: HomeAddressState }) {
  return (
    <section className={portal === 'field' ? 'fd-card stack' : 'pt-card stack'} aria-labelledby="home-t" data-testid="home-address-section">
      <h2 className="d4" id="home-t">Home address</h2>
      <p className="small muted">{WHY}</p>
      <HomeAddressForm portal={portal} address={state.home_address} postal={state.home_postal_code} button={state.missing ? 'Save my home address' : 'Change my home address'} />
    </section>
  );
}
