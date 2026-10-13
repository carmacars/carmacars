import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'No access', path: '/va', noindex: true, description: 'This area is for CarmaCars assistants.' });
export default function NoAccess() {
  return <div className="pt-empty"><h1 className="d3">This area is for CarmaCars assistants</h1><p className="muted">Your account does not have an assistant role. If you work with us, ask an Admin to add it.</p></div>;
}
