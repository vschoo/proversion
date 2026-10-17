/**
 * Education-level scoping — the single place that decides how classes,
 * subjects and financial items relate to education levels. Pure: shared by
 * the UI (filtering pickers) and the server (enforcing writes).
 */

export interface LevelClass {
  name: string;
  levelCode: string;
}

export interface LevelSubject {
  name: string;
  levelCode: string;
}

const norm = (v: string | null | undefined) => (v ?? "").trim().toLowerCase();

/** Education level of a class by name, or null when the class is not configured. */
export function levelOfClass(classes: LevelClass[], className: string | null | undefined): string | null {
  return classes.find((c) => norm(c.name) === norm(className))?.levelCode ?? null;
}

/** Subject names offered at any of the levels of the given classes. */
export function subjectsForClasses(
  classes: LevelClass[],
  subjects: LevelSubject[],
  classNames: string[],
): string[] {
  const levels = new Set(classNames.map((n) => levelOfClass(classes, n)).filter(Boolean) as string[]);
  return [...new Set(subjects.filter((s) => levels.has(s.levelCode)).map((s) => s.name))].sort();
}

/**
 * Valid (class, subject) teaching pairs: each chosen subject is paired only
 * with chosen classes at a level that offers it. Subjects that fit none of the
 * chosen classes are reported so the caller can refuse the save.
 */
export function teachingPairs(
  classes: LevelClass[],
  subjects: LevelSubject[],
  classNames: string[],
  subjectNames: string[],
): { pairs: { class_name: string; subject: string }[]; unmatched: string[] } {
  const pairs: { class_name: string; subject: string }[] = [];
  const matched = new Set<string>();
  for (const className of [...new Set(classNames)]) {
    const level = levelOfClass(classes, className);
    if (!level) continue;
    for (const subject of [...new Set(subjectNames)]) {
      if (subjects.some((s) => s.levelCode === level && norm(s.name) === norm(subject))) {
        pairs.push({ class_name: className, subject });
        matched.add(subject);
      }
    }
  }
  return { pairs, unmatched: [...new Set(subjectNames)].filter((s) => !matched.has(s)) };
}

/* ----------------------- financial level applicability ----------------------- */

/** Metadata key on financial list items holding the applicable level codes (comma list; empty = all levels). */
export const LEVELS_KEY = "levels";
/** Metadata key prefix for a per-level amount override, e.g. "amount:primary". */
export const LEVEL_AMOUNT_PREFIX = "amount:";

export function itemLevels(metadata: Record<string, unknown> | null | undefined): string[] {
  return String(metadata?.[LEVELS_KEY] ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** Whether a financial item applies at a level. Unknown level → only items open to every level. */
export function appliesToLevel(metadata: Record<string, unknown> | null | undefined, levelCode: string | null | undefined) {
  const levels = itemLevels(metadata);
  if (levels.length === 0) return true;
  return !!levelCode && levels.includes(levelCode);
}

/** The amount charged at a level: the per-level override, else the item's base amount. */
export function amountForLevel(metadata: Record<string, unknown> | null | undefined, levelCode: string | null | undefined) {
  const override = levelCode ? metadata?.[`${LEVEL_AMOUNT_PREFIX}${levelCode}`] : undefined;
  const n = Number(override !== undefined && override !== "" ? override : (metadata?.["amount"] ?? 0));
  return Number.isFinite(n) ? n : 0;
}
