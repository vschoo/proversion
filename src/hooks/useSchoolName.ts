import { useQuery } from "@tanstack/react-query";
import { useServerFn } from "@tanstack/react-start";
import { getPortalOverview } from "@/lib/admin.functions";

export const DEFAULT_SCHOOL_NAME = "School Management Portal";

/** Configured school name, shared via the portal-overview query cache. */
export function useSchoolName() {
  const fn = useServerFn(getPortalOverview);
  const { data } = useQuery({
    queryKey: ["portal-overview"],
    queryFn: () => fn(),
    staleTime: 60_000,
  });
  return { name: data?.schoolName || DEFAULT_SCHOOL_NAME, tagline: data?.schoolTagline ?? "" };
}
