import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'No access', path: '/investor', noindex: true, description: 'Statements for existing investors.' });
export default function NoAccess() {
  return <div className="pt-empty"><h1 className="d3">Nothing to show for this account</h1><p className="muted">This area holds statements for existing investors, invited by CarmaCars.</p></div>;
}
