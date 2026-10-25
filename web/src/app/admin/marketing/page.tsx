import { redirect } from 'next/navigation';

// Admin > Marketing (migration 0167) opens on Listings.
export default function Marketing() {
  redirect('/admin/marketing/listings');
}
