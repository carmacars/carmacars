import { pageMeta } from '@/features/seo/meta';
import { VerifyFile } from '@/features/signing/VerifyFile';

export const metadata = pageMeta({ title: 'Check a signed CarmaCars document', path: '/verify', noindex: true,
  description: 'Check that a signed CarmaCars document (a rental agreement, an owner, partner, investment or staff agreement, a form or an evidence file) is exactly the one CarmaCars recorded.' });

// Tamper evidence (migration 0154; every signed document since 0181): every signed document's SHA-256 is recorded when it is stored. Choose the file: the
// browser computes its SHA-256 (the file never leaves the device) and asks whether CarmaCars recorded it.
export default function VerifyPage() {
  return (
    <section className="section"><div className="wrap stack-lg" style={{ maxWidth: '40rem' }}>
      <header className="stack"><h1 className="d2">Check a signed document</h1>
        <p className="lead">Choose a signed document from CarmaCars: a rental agreement or amendment, an owner, partner, investment or staff agreement, a form, a schedule or an evidence file. We compare its fingerprint (SHA-256) with the one recorded when it was signed. A copy changed in any way does not match.</p></header>
      <VerifyFile />
      <p className="small muted">The file stays on your device: only its fingerprint is checked. The answer says whether the document was recorded and when, nothing about the people in it.</p>
    </div></section>
  );
}
