import { NotificationsTab as Notices } from '@/app/account/profile/NotificationsTab';
import type { OwnerCtx } from '@/features/owner/ctx';

// Account > Notifications: messages about your vehicles, invoices and payouts, and your email preferences on the same
// tab (before r27 the owner was sent to the renter portal for them). Statement and billing emails are always sent.
export function NotificationsTab({ user }: OwnerCtx) {
  return (
    <>
      <p className="ph__purpose">Messages about your vehicles, invoices and payouts. Statement and billing emails are always sent; choose the optional ones here.</p>
      <Notices user={user} />
    </>
  );
}
