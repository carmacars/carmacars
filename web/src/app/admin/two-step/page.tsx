import { pageMeta } from '@/features/seo/meta';

export const metadata = pageMeta({ title: 'Two-step sign-in', path: '/admin', noindex: true, description: 'Two-step sign-in is required.' });
export default function TwoStep() {
  return <div className="pt-empty"><h1 className="d3">Two-step sign-in is required</h1><p className="muted">Staff access needs a second step at sign-in. Sign out, sign in again and complete the second step with your authenticator app.</p></div>;
}
