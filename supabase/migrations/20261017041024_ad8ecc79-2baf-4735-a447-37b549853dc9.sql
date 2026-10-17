CREATE OR REPLACE FUNCTION public.validate_teaching_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  class_level text;
BEGIN
  SELECT c.level_code INTO class_level
  FROM public.school_classes c
  WHERE lower(c.name) = lower(btrim(NEW.class_name))
  ORDER BY c.active DESC
  LIMIT 1;

  IF class_level IS NULL THEN
    RAISE EXCEPTION 'Class "%" is not set up under System Configuration → Classes.', NEW.class_name
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.subjects s
    WHERE lower(s.name) = lower(btrim(NEW.subject))
      AND s.level_code = class_level
      AND s.active
  ) THEN
    RAISE EXCEPTION 'Subject "%" is not offered at the education level of class "%".', NEW.subject, NEW.class_name
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.validate_teaching_assignment() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS teaching_assignments_level_check ON public.teaching_assignments;
CREATE TRIGGER teaching_assignments_level_check
BEFORE INSERT OR UPDATE OF class_name, subject ON public.teaching_assignments
FOR EACH ROW EXECUTE FUNCTION public.validate_teaching_assignment();

CREATE INDEX IF NOT EXISTS subjects_level_name_idx ON public.subjects (level_code, lower(name));