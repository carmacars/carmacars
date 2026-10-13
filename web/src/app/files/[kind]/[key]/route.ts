import { redirect } from 'next/navigation';
import { currentUser } from '@/server/portal/data';
import { fileResponse, generatedFile, isDocKind, mayDownload, validKey } from '@/server/files';

// A generated document for a signed-in person (portals and admin screens): /files/<kind>/<record>.
// The database decides who may download it (app.file_access): staff by function, each customer only
// their own final records.
export const dynamic = 'force-dynamic';

export async function GET(req: Request, { params }: { params: Promise<{ kind: string; key: string }> }) {
  const { kind, key: raw } = await params;
  const key = decodeURIComponent(raw);
  if (!isDocKind(kind) || !validKey(key)) return new Response('Not found', { status: 404 });
  const user = await currentUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(new URL(req.url).pathname)}`);
  if (!(await mayDownload(user.id, kind, key))) return new Response('Not found', { status: 404 });
  const f = await generatedFile(kind, key, user.id);
  if (!f) return new Response('Not found', { status: 404 });
  return fileResponse(f, new URL(req.url).searchParams.has('download'));
}
