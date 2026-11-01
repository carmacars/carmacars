import { NextResponse } from 'next/server';
import { realUser } from '@/server/portal/data';

// Where the installed app opens (the manifest's start_url, migration 0300): a signed-in person goes to their portal
// (/choose-portal sends someone with one portal straight to it), anyone else to the home page.
export const dynamic = 'force-dynamic';

export async function GET(req: Request) {
  const user = await realUser().catch(() => null);
  return NextResponse.redirect(new URL(user ? '/choose-portal' : '/', req.url), 302);
}
