import type { SessionUser } from '@/lib/auth';
import type { OwnerHome } from '@/features/owner/types';

/** What a tab of a merged owner page gets from the page (the page checked the owner role once, requireOwner). */
export interface OwnerCtx { user: SessionUser; home: OwnerHome }
