import { sitemapFile } from '@/features/seo/sitemap';
export const revalidate = 3600;
export const GET = () => sitemapFile('cars');
