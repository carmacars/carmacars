import { door } from '@/server/door';

// R51 (5200, REQ-132): the staff member's own extension on their profile. The number behind it is never shown to anyone.
export async function MyLine({ userId, call, className }: { userId: string; call: 'va_read' | 'field_read'; className: string }) {
  const l = await door<{ extension: string | null; active: boolean }>(userId, call, 'my_line').catch(() => null);
  if (!l?.extension) return null;
  return (
    <section className={className} aria-labelledby="line-t" data-testid="my-line"><h2 className="d4" id="line-t">Your extension</h2>
      <p>Extension <b className="num">{l.extension}</b>. {l.active
        ? 'Callers reach you by pressing it on the CarmaCars phone menu. The call rings your browser phone in the portal and in the app while you are signed in, so keep a staff page open on your shift. A call you miss is in your alerts.'
        : 'Your line is being set up. You get an alert when calls to it ring here.'}</p>
    </section>
  );
}
