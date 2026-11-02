'use client';
import NextLink from 'next/link';
import { usePathname } from 'next/navigation';
import { forwardRef, type ComponentProps } from 'react';
import { staysOnPage } from '@/lib/nav/same-page';

// The site's one Link (Release 27): next/link, except that a link to the page you are on (a tab, a filter, a page of
// results, a sort: only the search parameters change) does not scroll back to the top. A link to another page does, as
// before. Every file imports this instead of next/link (the lint rule and nav.test.ts keep it so); pass scroll to decide
// by hand.
const Link = forwardRef<HTMLAnchorElement, ComponentProps<typeof NextLink>>(function Link({ scroll, href, ...rest }, ref) {
  const path = usePathname();
  return <NextLink ref={ref} href={href} scroll={scroll ?? (staysOnPage(href, path) ? false : undefined)} {...rest} />;
});
export default Link;
