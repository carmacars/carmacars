'use client';
import { useEffect } from 'react';
import { installFormGuard } from '@/lib/forms/guard-dom';

// r40-forms: one mechanism for every form of the site (src/lib/forms/guard-dom.ts). When a form cannot be sent it shows a summary
// of what is missing or wrong, marks each field and moves the focus to the first one. Renders nothing.
export function FormGuard() {
  useEffect(() => installFormGuard(), []);
  return null;
}
