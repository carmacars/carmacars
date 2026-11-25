import 'server-only';
import { siteUrl } from '@/lib/site';
import { readToken, signToken } from '@/server/links';
import { FILE_TTL_SECONDS, fileRef, hasFiles, swapFiles, type FileRef } from '@/features/api-access/files';

// r50 (3870): a connector file link, signed with LINK_SIGNING_KEY (pickLinkSecret) for ten minutes and bound to the exact
// bucket and storage key the database chose; /api/connector/file checks it and serves the file without a staff session.
const PURPOSE = 'connector_file';

export async function fileLink(f: FileRef): Promise<string> {
  const t = await signToken(PURPOSE, { b: f.bucket, k: f.key, n: f.name ?? null }, FILE_TTL_SECONDS);
  return `${siteUrl()}/api/connector/file?t=${encodeURIComponent(t)}`;
}

export async function readFileLink(token: string | null): Promise<FileRef | null> {
  const p = await readToken<{ b: string; k: string; n: string | null }>(PURPOSE, token);
  return p ? fileRef({ _file: { bucket: p.b, key: p.k, name: p.n ?? undefined } }) : null;
}

/** The answer of a connector read with its files as signed links. */
export async function signConnectorFiles(v: unknown): Promise<unknown> {
  return hasFiles(v) ? swapFiles(v, fileLink) : v;
}
