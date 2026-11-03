import { redirect } from 'next/navigation';

// r27: staff alerts (field jobs, availability) link here; the staff list is Team > Staff and roles.
export default function Moved() {
  redirect('/admin/settings/staff');
}
