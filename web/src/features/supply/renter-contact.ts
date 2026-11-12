// Add a rental: when the renter must be reachable (migration 2310). A rental billed to an insurer that does not block the
// calendar needs only the renter's name: no account, phone or email. Every
// other rental still asks for the email and the phone. The database enforces the same rule; this keeps the form honest.

export interface RenterContactCase {
  /** the "paid by" choice on the form */ paidBy: string;
  /** the "Blocks the car's calendar" box */ blocks: boolean;
  /** an Admin's placeholder booking */ placeholder?: boolean;
}

/** True when the renter's email and phone are optional: billed to an insurer and off the calendar. */
export function contactOptional(c: RenterContactCase): boolean {
  return c.paidBy === 'insurer' && !c.blocks && !c.placeholder;
}

/** True when the renter's date of birth is optional (migration 2510): the rent is billed to an insurer. The name is still needed. */
export function dobOptional(c: RenterContactCase): boolean {
  return c.paidBy === 'insurer';
}

export const DOB_OPTIONAL_HINT = 'Optional when billed to an insurer. Decides the young driver fee';

export const CONTACT_OPTIONAL_NOTE = 'Billed to an insurer and not on the calendar: the renter needs only a name. No email, phone or account. Nothing is sent to the renter without one.';

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export interface NewRenterFields { full_name?: string; date_of_birth?: string; email?: string; mobile?: string }

/** The first problem with a new renter's details, in words, or null. */
export function renterProblem(f: NewRenterFields, c: RenterContactCase): string | null {
  const email = (f.email ?? '').trim();
  const mobile = (f.mobile ?? '').trim();
  if (dobOptional(c)) {
    if (!(f.full_name ?? '').trim()) return 'Enter the renter\'s full legal name.';
  } else if (!(f.full_name ?? '').trim() || !(f.date_of_birth ?? '').trim()) return 'Enter the renter\'s full legal name and date of birth.';
  if (contactOptional(c)) {
    if (email && !EMAIL.test(email)) return 'The email address does not look right: correct it, or leave it empty.';
    return null;
  }
  if (!email || !EMAIL.test(email)) return 'Enter the renter\'s email address (like name@example.com).';
  if (!mobile) return 'Enter the renter\'s phone number.';
  return null;
}
