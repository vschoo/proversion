import { FALLBACK_BRANDING, type Branding } from "./branding";

export type { Branding };
export { FALLBACK_BRANDING };

/** Reads the public branding through the narrow get_public_branding() database function. */
export async function readBranding(client: any): Promise<Branding> {
  const { data, error } = await client.rpc("get_public_branding");
  if (error) { console.error("get_public_branding failed", error.message); return FALLBACK_BRANDING; }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return FALLBACK_BRANDING;
  return {
    name: row.name?.trim() || FALLBACK_BRANDING.name,
    shortName: row.short_name ?? "",
    tagline: row.tagline ?? "",
    motto: row.motto ?? "",
    establishedYear: row.established_year ?? null,
    logoUrl: row.logo_url ?? null,
    primaryColor: row.primary_color || FALLBACK_BRANDING.primaryColor,
    accentColor: row.accent_color || FALLBACK_BRANDING.accentColor,
    language: row.language || "en",
  };
}
