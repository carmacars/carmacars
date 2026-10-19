import { sitemapIndex } from '@/features/seo/sitemap';
// The sitemap index (0061): robots.txt names it; each part is its own file.
export const revalidate = 3600;
export const GET = () => sitemapIndex();
