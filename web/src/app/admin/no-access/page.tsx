import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'Admin', path: '/admin', noindex: true, description: 'Admin access.' });
export default function NoAccess() {
  return <div className="pt-empty"><h1 className="d3">This area is for CarmaCars admins</h1><p className="muted">Your account does not have admin access. If it should, ask a Principal to add the role.</p><Link prefetch={false} className="btn btn--primary" href="/">Home</Link></div>;
}
