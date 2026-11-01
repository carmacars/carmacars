import { redirect } from 'next/navigation';

// Admin > Marketing (migration 0167) opens on Marketplace (0410; Listings before).
export default function Marketing() {
  redirect('/admin/marketing/marketplace');
}
