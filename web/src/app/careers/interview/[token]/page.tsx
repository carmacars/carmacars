import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { Interview } from '@/features/careers/Interview';
import { interviewView } from '@/server/interviews';

// The candidate's interview page (migration 0380): the personal link of the email a remote assistant applicant gets after
// screening. The consent, then the questions, answered out loud or typed. No sign-in: the link is the key.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your interview | CarmaCars', path: '/careers/interview', noindex: true,
  description: 'Your CarmaCars interview: a few questions about the role, answered out loud or in writing, whenever it suits you.' });
export default async function InterviewPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const v = await interviewView(token);
  return (
    <div className="p-careers">
      <section className="section">
        <div className="wrap cr-narrow stack-lg">
          {v && v.ok
            ? <Interview token={token} initial={v} />
            : <><h1 className="d2">{v && v.error === 'closed' ? 'This interview is closed' : 'This link is not valid'}</h1>
                <p>{v && v.error === 'closed' ? 'Your application has moved on. We have emailed you about it.' : 'It may be incomplete. Open the link in our email again, or reply to that email and we will help.'}</p>
                <p><Link prefetch={false} className="link" href="/careers">Open roles</Link></p></>}
        </div>
      </section>
    </div>
  );
}
