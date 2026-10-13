import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'No access', path: '/field', noindex: true, description: 'This area is for CarmaCars field staff.' });
export default function NoAccess() {
  return <div className="pt-empty"><h1 className="d3">This area is for CarmaCars field staff</h1><p className="muted">Your account does not have a field role. Ask Fleet if you think it should.</p></div>;
}
