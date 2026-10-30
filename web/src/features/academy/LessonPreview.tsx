'use client';
import '@/features/academy/academy.css';
import { ScenePlayer } from './ScenePlayer';
import type { Lesson } from './model';

// The editor's preview of a lesson (Admin > Academy): the same player, nothing recorded.
export function LessonPreview({ lesson }: { lesson: Lesson }) {
  return <details className="ad-inline"><summary className="link small">Preview ({lesson.scenes.length} scenes)</summary><ScenePlayer lesson={lesson} testId={`preview-${lesson.id.slice(0, 8)}`} /></details>;
}
