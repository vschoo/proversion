import { useEffect, useState } from "react";
import { useServerFn } from "@tanstack/react-start";
import { getSubjectOptions } from "@/lib/config.functions";
import type { LevelSubject } from "@/lib/education-levels";

/**
 * Subjects configured under System Configuration → Subjects, each tied to an
 * education level. Single source for every module that picks a subject;
 * scope them to classes with subjectsForClasses (src/lib/education-levels.ts).
 */
export function useSubjectOptions(): { subjects: string[]; catalog: LevelSubject[]; loading: boolean } {
  const load = useServerFn(getSubjectOptions);
  const [catalog, setCatalog] = useState<LevelSubject[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    void load()
      .then((rows) => {
        if (active) setCatalog(rows as LevelSubject[]);
      })
      .catch(() => setCatalog([]))
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, []);

  return { subjects: [...new Set(catalog.map((s) => s.name))].sort(), catalog, loading };
}
