/**
 * Branding — the single client-safe definition of the school's identity
 * (name, short name, tagline, motto, year founded, logo, colours, language)
 * and how the emblem is sized in each place it appears. Read only through
 * useBranding(); drawn only by src/components/brand/*.
 */

export interface Branding {
  name: string;
  shortName: string;
  tagline: string;
  motto: string;
  establishedYear: number | null;
  logoUrl: string | null;
  primaryColor: string;
  accentColor: string;
  language: string;
}

export const DEFAULT_SCHOOL_NAME = "School Management Portal";
export const DEFAULT_BRAND_PRIMARY = "#2f6f8f";
export const DEFAULT_BRAND_ACCENT = "#d9a441";

export const FALLBACK_BRANDING: Branding = {
  name: DEFAULT_SCHOOL_NAME,
  shortName: "",
  tagline: "",
  motto: "",
  establishedYear: null,
  logoUrl: null,
  primaryColor: DEFAULT_BRAND_PRIMARY,
  accentColor: DEFAULT_BRAND_ACCENT,
  language: "en",
};

/** Initials shown in the emblem centre when no logo is uploaded (or the configured short name). */
export function brandInitials(b: Pick<Branding, "name" | "shortName">): string {
  if (b.shortName.trim()) return b.shortName.trim().slice(0, 4).toUpperCase();
  const words = b.name.split(/\s+/).filter((w) => /^[A-Za-z0-9]/.test(w) && !/^(of|the|and|&)$/i.test(w));
  return (words.map((w) => w[0]).join("").slice(0, 3) || "S").toUpperCase();
}

/**
 * Where the emblem appears → its size and how much detail it carries.
 * Small placements show the mark only; larger ones draw the full crest with
 * the name ring, motto and year. Add a context here rather than sizing ad hoc.
 */
export const BRAND_CONTEXTS = {
  avatar: { size: 32, detail: "mark" },
  nav: { size: 36, detail: "mark" },
  module: { size: 48, detail: "mark" },
  dashboard: { size: 88, detail: "crest" },
  signin: { size: 128, detail: "crest" },
  document: { size: 84, detail: "crest" },
  watermark: { size: 420, detail: "crest" },
  preview: { size: 160, detail: "crest" },
} as const satisfies Record<string, { size: number; detail: "mark" | "crest" }>;

export type BrandContext = keyof typeof BRAND_CONTEXTS;

/** Uploaded images are served through the app (private storage, public read of these folders only). */
export const MEDIA_ROUTE = "/api/public/media/";
export const MEDIA_FOLDERS = ["branding", "avatars"] as const;
export const MAX_IMAGE_BYTES = 1_500_000;
export const IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp"] as const;

export function isMediaPath(path: string) {
  return (
    /^[a-z]+\/[A-Za-z0-9._-]+$/.test(path) &&
    MEDIA_FOLDERS.some((f) => path.startsWith(`${f}/`)) &&
    !path.includes("..")
  );
}

/** A user's picture, falling back to the school logo (null → draw the emblem). */
export function avatarSource(avatarUrl: string | null | undefined, branding: Pick<Branding, "logoUrl">) {
  return avatarUrl || branding.logoUrl || null;
}
