ALTER TABLE public.school_branding
  ADD COLUMN IF NOT EXISTS motto text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS short_name text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS established_year integer;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS avatar_url text;

DROP FUNCTION IF EXISTS public.get_public_branding();
CREATE FUNCTION public.get_public_branding()
RETURNS TABLE(name text, tagline text, logo_url text, motto text, short_name text,
              established_year integer, primary_color text, accent_color text, language text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(NULLIF(btrim(b.display_name), ''), s.name)::text,
         COALESCE(b.tagline, '')::text, b.logo_url::text,
         COALESCE(b.motto, '')::text, COALESCE(b.short_name, '')::text, b.established_year,
         COALESCE(b.primary_color, '#2f6f8f')::text, COALESCE(b.accent_color, '#d9a441')::text,
         COALESCE(b.language, 'en')::text
  FROM public.schools s LEFT JOIN public.school_branding b ON b.school_id = s.id
  ORDER BY s.active DESC, s.created_at ASC LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.get_public_branding() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_branding() TO anon, authenticated, service_role;