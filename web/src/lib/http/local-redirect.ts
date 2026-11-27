import { NextResponse } from 'next/server';

// A redirect to a path on this site. On the company server the app sits behind Caddy, so req.url reads
// http://localhost:3000/...: new URL(path, req.url) sent installed apps and signed-out visitors to localhost.
// A relative Location keeps the browser on the host it asked (carmacars.ca, www, new.).
export function localRedirect(path: string, status = 302, headers: Record<string, string> = {}): NextResponse {
  if (!path.startsWith('/') || path.startsWith('//') || path.includes('\\')) throw new Error('localRedirect takes a path on this site');
  return new NextResponse(null, { status, headers: { ...headers, Location: path } });
}

// The Location of a redirect to a signed file link: a path on this site (local storage) or an https address (R2, Supabase),
// passed on as it is, never joined to req.url.
export function fileLocation(url: string): string {
  if (/^https?:\/\//.test(url) || (url.startsWith('/') && !url.startsWith('//'))) return url;
  throw new Error('fileLocation takes a path on this site or an http address');
}
