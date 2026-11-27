import { NextResponse } from 'next/server';

// A redirect to a path on this site. On the company server the app sits behind Caddy, so req.url reads
// http://localhost:3000/...: new URL(path, req.url) sent installed apps and signed-out visitors to localhost.
// A relative Location keeps the browser on the host it asked (carmacars.ca, www, new.).
export function localRedirect(path: string, status = 302): NextResponse {
  if (!path.startsWith('/') || path.startsWith('//')) throw new Error('localRedirect takes a path on this site');
  return new NextResponse(null, { status, headers: { Location: path } });
}
