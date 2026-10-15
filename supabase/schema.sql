-- =============================================================================
-- School Management Portal — canonical, idempotent database schema
-- -----------------------------------------------------------------------------
-- Single source of truth for the whole database. Safe to run:
--   * on a brand-new Supabase project (creates everything), and
--   * on an existing database any number of times (only fills gaps, never
--     drops tables, columns or data).
-- Conventions used throughout:
--   * tables: CREATE TABLE IF NOT EXISTS, later columns via ADD COLUMN IF NOT EXISTS
--   * functions: CREATE OR REPLACE; triggers: CREATE OR REPLACE TRIGGER
--   * policies: DROP POLICY IF EXISTS + CREATE (also removes legacy names)
--   * grants / RLS / updated_at triggers applied centrally by helper loops
--   * seed rows: ON CONFLICT DO NOTHING
-- Access helpers live in the non-exposed `private` schema.
-- =============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. Types
-- ----------------------------------------------------------------------------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'app_role' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.app_role AS ENUM ('super_admin','school_manager','staff','student','parent');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'access_level' AND typnamespace = 'public'::regnamespace) THEN
    CREATE TYPE public.access_level AS ENUM ('super_administrator','administrator','standard','basic');
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA private TO authenticated, service_role;

CREATE SEQUENCE IF NOT EXISTS public.admission_number_seq;
CREATE SEQUENCE IF NOT EXISTS public.employee_id_seq START 1;

-- ----------------------------------------------------------------------------
-- 2. Generic trigger function
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

-- ----------------------------------------------------------------------------
-- 3. Identity & security
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  role public.app_role NOT NULL DEFAULT 'student',
  access_level public.access_level NOT NULL DEFAULT 'basic',
  status text NOT NULL DEFAULT 'active',
  last_login timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS username text,
  ADD COLUMN IF NOT EXISTS gender text,
  ADD COLUMN IF NOT EXISTS department text,
  ADD COLUMN IF NOT EXISTS class_name text,
  ADD COLUMN IF NOT EXISTS two_factor_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS permissions jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS force_password_change boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS password_reset_at timestamptz,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS position text,
  ADD COLUMN IF NOT EXISTS employee_id text,
  ADD COLUMN IF NOT EXISTS salary numeric(12,2),
  ADD COLUMN IF NOT EXISTS start_date date,
  ADD COLUMN IF NOT EXISTS admission_number text;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'profiles_employee_id_key') THEN
    ALTER TABLE public.profiles ADD CONSTRAINT profiles_employee_id_key UNIQUE (employee_id);
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS profiles_username_key ON public.profiles (lower(username)) WHERE username IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS profiles_admission_number_key ON public.profiles (admission_number) WHERE admission_number IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);

CREATE TABLE IF NOT EXISTS public.password_reset_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  note text,
  status text NOT NULL DEFAULT 'pending',
  handled_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  handled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,
  description text NOT NULL DEFAULT '',
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_email text,
  target_user_id uuid,
  target_email text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.security_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  singleton boolean NOT NULL DEFAULT true UNIQUE,
  allowed_ips text NOT NULL DEFAULT '',
  max_login_attempts integer NOT NULL DEFAULT 5,
  lockout_duration integer NOT NULL DEFAULT 30,
  session_timeout integer NOT NULL DEFAULT 30,
  max_concurrent_sessions integer NOT NULL DEFAULT 3,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Role helpers (private schema, SECURITY DEFINER to avoid RLS recursion)
CREATE OR REPLACE FUNCTION private.has_role(_user_id uuid, _role public.app_role)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role) $$;

CREATE OR REPLACE FUNCTION private.is_admin(_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role IN ('super_admin','school_manager')) $$;

-- Legacy public copies were replaced by the private ones.
DROP FUNCTION IF EXISTS public.has_role(uuid, public.app_role);
DROP FUNCTION IF EXISTS public.is_admin(uuid);

-- ----------------------------------------------------------------------------
-- 4. School catalogue & configuration
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.school_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.education_levels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  sort_order integer NOT NULL DEFAULT 1,
  min_age integer,
  max_age integer,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.schools (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  code text NOT NULL UNIQUE,
  country text NOT NULL DEFAULT '',
  region text NOT NULL DEFAULT '',
  timezone text NOT NULL DEFAULT 'UTC',
  currency text NOT NULL DEFAULT 'USD',
  locale text NOT NULL DEFAULT 'en-US',
  type_code text NOT NULL DEFAULT 'private',
  level_codes text[] NOT NULL DEFAULT '{}',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.schools
  ADD COLUMN IF NOT EXISTS district text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS town text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS community text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS postal_address text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS gps_address text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS public.subjects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid REFERENCES public.schools(id) ON DELETE CASCADE,
  level_code text NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  credits numeric,
  elective boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, level_code, code)
);

CREATE TABLE IF NOT EXISTS public.school_classes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  level_code text NOT NULL,
  name text NOT NULL,
  sort_order integer NOT NULL DEFAULT 1,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, name)
);
CREATE INDEX IF NOT EXISTS school_classes_school_level_idx ON public.school_classes (school_id, level_code, sort_order);

CREATE TABLE IF NOT EXISTS public.tenant_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL UNIQUE REFERENCES public.schools(id) ON DELETE CASCADE,
  positions text[] NOT NULL DEFAULT '{}',
  departments text[] NOT NULL DEFAULT '{}',
  rating_scale jsonb NOT NULL DEFAULT '[]'::jsonb,
  schedule_types text[] NOT NULL DEFAULT '{}',
  grading_system text NOT NULL DEFAULT 'letter',
  academic_year_start_month integer NOT NULL DEFAULT 9,
  week_starts_on text NOT NULL DEFAULT 'monday',
  features jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenant_settings_grading_chk CHECK (grading_system IN ('letter','percentage','gpa','points')),
  CONSTRAINT tenant_settings_week_chk CHECK (week_starts_on IN ('monday','sunday')),
  CONSTRAINT tenant_settings_month_chk CHECK (academic_year_start_month BETWEEN 1 AND 12)
);

CREATE TABLE IF NOT EXISTS public.school_branding (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL UNIQUE REFERENCES public.schools(id) ON DELETE CASCADE,
  display_name text NOT NULL DEFAULT '',
  tagline text NOT NULL DEFAULT '',
  logo_url text,
  primary_color text NOT NULL DEFAULT '#2f6f8f',
  accent_color text NOT NULL DEFAULT '#d9a441',
  language text NOT NULL DEFAULT 'en',
  currency text NOT NULL DEFAULT 'USD',
  locale text NOT NULL DEFAULT 'en-US',
  date_format text NOT NULL DEFAULT 'dmy',
  show_powered_by boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT school_branding_date_chk CHECK (date_format IN ('dmy','mdy','ymd'))
);

CREATE TABLE IF NOT EXISTS public.numbering_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL UNIQUE REFERENCES public.schools(id) ON DELETE CASCADE,
  school_code text NOT NULL DEFAULT '0000' CHECK (school_code ~ '^[0-9]{4}$'),
  admission_format text NOT NULL DEFAULT '{SCHOOL}{YY}{SEQ}',
  admission_total_digits integer NOT NULL DEFAULT 10 CHECK (admission_total_digits BETWEEN 6 AND 20),
  admission_year_digits integer NOT NULL DEFAULT 2 CHECK (admission_year_digits BETWEEN 0 AND 4),
  admission_sequence_digits integer NOT NULL DEFAULT 4 CHECK (admission_sequence_digits BETWEEN 1 AND 8),
  admission_sequence_start integer NOT NULL DEFAULT 1 CHECK (admission_sequence_start >= 0),
  employee_format text NOT NULL DEFAULT '{SCHOOL}{YY}{SEQ}',
  employee_total_digits integer NOT NULL DEFAULT 7 CHECK (employee_total_digits BETWEEN 5 AND 20),
  employee_year_digits integer NOT NULL DEFAULT 2 CHECK (employee_year_digits BETWEEN 0 AND 4),
  employee_sequence_digits integer NOT NULL DEFAULT 1 CHECK (employee_sequence_digits BETWEEN 1 AND 8),
  employee_sequence_start integer NOT NULL DEFAULT 1 CHECK (employee_sequence_start >= 0),
  employee_allocation_mode text NOT NULL DEFAULT 'compact' CHECK (employee_allocation_mode IN ('compact','random')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.numbering_counters (
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('admission','employee')),
  year_key text NOT NULL,
  last_value bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (school_id, kind, year_key)
);

-- ----------------------------------------------------------------------------
-- 5. Staff
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_performance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  review_period text NOT NULL,
  rating text NOT NULL,
  rating_score integer NOT NULL DEFAULT 3,
  comments text NOT NULL DEFAULT '',
  reviewer_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.staff_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  schedule_date date NOT NULL,
  start_time time NOT NULL,
  end_time time NOT NULL,
  schedule_type text NOT NULL,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.offer_letters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  candidate_name text NOT NULL,
  candidate_email text NOT NULL,
  position text NOT NULL,
  salary numeric(12,2) NOT NULL DEFAULT 0,
  start_date date NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.class_teachers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  class_name text NOT NULL UNIQUE,
  teacher_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  teacher_name text NOT NULL DEFAULT '',
  teacher_email text NOT NULL DEFAULT '',
  teacher_phone text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.teaching_assignments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  teacher_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  class_name text NOT NULL,
  subject text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (teacher_id, class_name, subject)
);
CREATE INDEX IF NOT EXISTS teaching_assignments_teacher_idx ON public.teaching_assignments (teacher_id);
CREATE INDEX IF NOT EXISTS teaching_assignments_class_idx ON public.teaching_assignments (class_name);

-- ----------------------------------------------------------------------------
-- 6. Students
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_number text UNIQUE,
  student_name text NOT NULL,
  dob date,
  place_of_birth text,
  class_admitted text NOT NULL,
  previous_school text,
  previous_class text,
  last_attendance date,
  reason_for_leaving text,
  disability_status text NOT NULL DEFAULT 'No',
  disability_type text,
  assistance_needed text,
  gender text NOT NULL DEFAULT 'Other',
  parent_name text NOT NULL,
  relationship text,
  parent_phone text,
  alt_contact text,
  hometown text,
  hometown_district text,
  residence text,
  residence_district text,
  parent_email text NOT NULL,
  emergency_name text,
  emergency_phone text,
  emergency_relationship text,
  emergency_residence text,
  emergency_residence_district text,
  address text,
  city text,
  community text,
  digital_address text,
  status text NOT NULL DEFAULT 'admitted',
  student_profile_id uuid,
  parent_profile_id uuid,
  student_login_email text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admissions_parent_email_idx ON public.admissions (lower(parent_email));
CREATE INDEX IF NOT EXISTS admissions_parent_profile_idx ON public.admissions (parent_profile_id);
CREATE INDEX IF NOT EXISTS admissions_student_profile_idx ON public.admissions (student_profile_id);

CREATE TABLE IF NOT EXISTS public.student_performance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_id uuid NOT NULL REFERENCES public.admissions(id) ON DELETE CASCADE,
  term text NOT NULL,
  subject text NOT NULL,
  score numeric NOT NULL DEFAULT 0,
  grade text NOT NULL DEFAULT '',
  assessment_type text NOT NULL DEFAULT 'exam',
  remarks text NOT NULL DEFAULT '',
  recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.student_attendance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_id uuid NOT NULL REFERENCES public.admissions(id) ON DELETE CASCADE,
  attendance_date date NOT NULL DEFAULT CURRENT_DATE,
  status text NOT NULL DEFAULT 'present',
  note text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (admission_id, attendance_date)
);

CREATE TABLE IF NOT EXISTS public.student_fees (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_id uuid NOT NULL REFERENCES public.admissions(id) ON DELETE CASCADE,
  term text NOT NULL,
  amount_due numeric NOT NULL DEFAULT 0,
  amount_paid numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'unpaid',
  due_date date,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.student_exeat (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_id uuid NOT NULL REFERENCES public.admissions(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'in_school',
  reason text NOT NULL DEFAULT '',
  destination text NOT NULL DEFAULT '',
  signed_by_name text NOT NULL DEFAULT '',
  signed_by_id uuid,
  departed_at timestamptz,
  return_at timestamptz,
  returned_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS student_exeat_admission_idx ON public.student_exeat (admission_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.student_assessments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admission_id uuid NOT NULL REFERENCES public.admissions(id) ON DELETE CASCADE,
  class_name text NOT NULL DEFAULT '',
  term text NOT NULL DEFAULT '',
  subject text NOT NULL,
  assessment_type text NOT NULL DEFAULT 'Exam',
  score numeric NOT NULL DEFAULT 0,
  out_of numeric NOT NULL DEFAULT 100 CHECK (out_of > 0),
  remark text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS student_assessments_admission_idx ON public.student_assessments (admission_id);
CREATE INDEX IF NOT EXISTS student_assessments_created_idx ON public.student_assessments (created_at DESC);

-- ----------------------------------------------------------------------------
-- 7. Finance
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.finance_income (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_date date NOT NULL DEFAULT current_date,
  description text NOT NULL,
  category text NOT NULL DEFAULT 'other',
  amount numeric(14,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'received',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS finance_income_date_idx ON public.finance_income (entry_date DESC);

CREATE TABLE IF NOT EXISTS public.finance_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_date date NOT NULL DEFAULT current_date,
  description text NOT NULL,
  category text NOT NULL DEFAULT 'other',
  amount numeric(14,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'paid',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS finance_expenses_date_idx ON public.finance_expenses (entry_date DESC);

CREATE TABLE IF NOT EXISTS public.finance_payroll (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  employee_id text,
  employee_name text NOT NULL,
  position text,
  basic_salary numeric(14,2) NOT NULL DEFAULT 0,
  allowances numeric(14,2) NOT NULL DEFAULT 0,
  deductions numeric(14,2) NOT NULL DEFAULT 0,
  net_salary numeric(14,2) GENERATED ALWAYS AS (basic_salary + allowances - deductions) STORED,
  period text,
  status text NOT NULL DEFAULT 'pending',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.finance_config_sections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  area_key text NOT NULL,
  section_key text NOT NULL,
  version integer NOT NULL DEFAULT 1,
  status text NOT NULL DEFAULT 'draft',
  effective_from date,
  effective_to date,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text NOT NULL DEFAULT '',
  created_by uuid,
  approved_by uuid,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, section_key, version)
);
CREATE INDEX IF NOT EXISTS finance_config_sections_lookup ON public.finance_config_sections (school_id, section_key, status);

CREATE TABLE IF NOT EXISTS public.finance_reference_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  list_key text NOT NULL,
  code text NOT NULL,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  parent_code text,
  sort_order integer NOT NULL DEFAULT 1,
  active boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, list_key, code)
);
CREATE INDEX IF NOT EXISTS finance_reference_items_lookup ON public.finance_reference_items (school_id, list_key, sort_order);

CREATE TABLE IF NOT EXISTS public.finance_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid NOT NULL REFERENCES public.schools(id) ON DELETE CASCADE,
  rule_key text NOT NULL,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  priority integer NOT NULL DEFAULT 1,
  conditions jsonb NOT NULL DEFAULT '{}'::jsonb,
  actions jsonb NOT NULL DEFAULT '{}'::jsonb,
  effective_from date,
  effective_to date,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (school_id, rule_key, name)
);
CREATE INDEX IF NOT EXISTS finance_rules_lookup ON public.finance_rules (school_id, rule_key, priority);

CREATE TABLE IF NOT EXISTS public.finance_config_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id uuid REFERENCES public.schools(id) ON DELETE CASCADE,
  section_key text NOT NULL,
  action text NOT NULL,
  description text NOT NULL DEFAULT '',
  actor_id uuid,
  actor_email text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS finance_config_audit_lookup ON public.finance_config_audit (school_id, created_at DESC);

-- ----------------------------------------------------------------------------
-- 8. Business functions (need the tables above)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.owns_admission(_admission_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.admissions a WHERE a.id = _admission_id
    AND (a.parent_profile_id = auth.uid() OR a.student_profile_id = auth.uid()))
$$;

CREATE OR REPLACE FUNCTION private.staff_teaches_class(_class_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, private AS $$
  SELECT EXISTS (SELECT 1 FROM public.class_teachers ct WHERE ct.class_name = _class_name
    AND (ct.teacher_id = auth.uid()
      OR lower(ct.teacher_email) = lower(COALESCE((SELECT p.email FROM public.profiles p WHERE p.id = auth.uid()), ''))))
$$;

CREATE OR REPLACE FUNCTION private.staff_teaches_admission(_admission_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, private AS $$
  SELECT EXISTS (SELECT 1 FROM public.admissions a WHERE a.id = _admission_id
    AND private.staff_teaches_class(a.class_admitted))
$$;

-- One numbering engine for admission numbers and employee IDs.
CREATE OR REPLACE FUNCTION public.next_generated_number(_kind text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  cfg public.numbering_settings%ROWTYPE;
  fmt text; year_digits int; seq_digits int; seq_start bigint; mode text;
  year_part text; seq_value bigint; max_value bigint; candidate text;
  attempts int := 0; taken boolean;
BEGIN
  SELECT ns.* INTO cfg FROM public.numbering_settings ns
  JOIN public.schools s ON s.id = ns.school_id
  ORDER BY s.active DESC, s.created_at ASC LIMIT 1;
  IF cfg.id IS NULL THEN RETURN NULL; END IF;

  IF _kind = 'admission' THEN
    fmt := cfg.admission_format; year_digits := cfg.admission_year_digits;
    seq_digits := cfg.admission_sequence_digits; seq_start := cfg.admission_sequence_start;
    mode := 'compact';
  ELSE
    fmt := cfg.employee_format; year_digits := cfg.employee_year_digits;
    seq_digits := cfg.employee_sequence_digits; seq_start := cfg.employee_sequence_start;
    mode := cfg.employee_allocation_mode;
  END IF;

  year_part := CASE WHEN year_digits = 0 THEN '' ELSE right(to_char(now(), 'YYYY'), year_digits) END;
  max_value := power(10, seq_digits)::bigint - 1;

  IF mode = 'random' THEN
    WHILE attempts < 300 LOOP
      attempts := attempts + 1;
      seq_value := seq_start + floor(random() * GREATEST(max_value - seq_start + 1, 1))::bigint;
      candidate := replace(replace(replace(fmt, '{SCHOOL}', cfg.school_code), '{YY}', year_part),
                           '{SEQ}', lpad(seq_value::text, seq_digits, '0'));
      IF _kind = 'admission' THEN
        SELECT EXISTS (SELECT 1 FROM public.admissions WHERE admission_number = candidate)
            OR EXISTS (SELECT 1 FROM public.profiles WHERE admission_number = candidate) INTO taken;
      ELSE
        SELECT EXISTS (SELECT 1 FROM public.profiles WHERE employee_id = candidate) INTO taken;
      END IF;
      IF NOT taken THEN RETURN candidate; END IF;
    END LOOP;
  END IF;

  INSERT INTO public.numbering_counters (school_id, kind, year_key, last_value)
  VALUES (cfg.school_id, _kind, year_part, seq_start)
  ON CONFLICT (school_id, kind, year_key)
  DO UPDATE SET last_value = GREATEST(public.numbering_counters.last_value + 1, seq_start), updated_at = now()
  RETURNING last_value INTO seq_value;

  RETURN replace(replace(replace(fmt, '{SCHOOL}', cfg.school_code), '{YY}', year_part),
                 '{SEQ}', lpad(seq_value::text, seq_digits, '0'));
END; $$;

CREATE OR REPLACE FUNCTION public.assign_admission_number() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.role = 'student' AND COALESCE(NEW.admission_number, '') = '' THEN
    NEW.admission_number := COALESCE(public.next_generated_number('admission'),
      'ADM-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.admission_number_seq')::text, 4, '0'));
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.assign_admission_row_number() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF COALESCE(NEW.admission_number, '') = '' THEN
    NEW.admission_number := COALESCE(public.next_generated_number('admission'),
      'ADM-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.admission_number_seq')::text, 4, '0'));
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.assign_employee_id() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.role IN ('staff','school_manager') AND COALESCE(NEW.employee_id, '') = '' THEN
    NEW.employee_id := COALESCE(public.next_generated_number('employee'),
      'EMP-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.employee_id_seq')::text, 4, '0'));
  END IF;
  RETURN NEW;
END; $$;

-- Public, narrow read of the school name/tagline/logo (sign-in page, titles).
CREATE OR REPLACE FUNCTION public.get_public_branding()
RETURNS TABLE(name text, tagline text, logo_url text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(NULLIF(btrim(b.display_name), ''), s.name)::text,
         COALESCE(b.tagline, '')::text, b.logo_url::text
  FROM public.schools s LEFT JOIN public.school_branding b ON b.school_id = s.id
  ORDER BY s.active DESC, s.created_at ASC LIMIT 1
$$;

-- ----------------------------------------------------------------------------
-- 9. Triggers
-- ----------------------------------------------------------------------------
-- updated_at on every table that has the column (centralised, future-proof).
DO $$ DECLARE t text; BEGIN
  FOR t IN SELECT c.table_name FROM information_schema.columns c
           JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
           WHERE c.table_schema = 'public' AND c.column_name = 'updated_at' AND tb.table_type = 'BASE TABLE'
             AND c.table_name <> 'numbering_counters'
  LOOP
    -- Keep the historical trigger names where they differ from <table>_updated_at.
    EXECUTE format('CREATE OR REPLACE TRIGGER %I BEFORE UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_updated_at()',
      CASE t WHEN 'school_classes' THEN 'school_classes_set_updated_at'
             WHEN 'student_assessments' THEN 'student_assessments_set_updated_at'
             ELSE t || '_updated_at' END, t);
  END LOOP;
END $$;

CREATE OR REPLACE TRIGGER profiles_employee_id BEFORE INSERT OR UPDATE OF role ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.assign_employee_id();
CREATE OR REPLACE TRIGGER profiles_admission_number BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.assign_admission_number();
CREATE OR REPLACE TRIGGER admissions_number BEFORE INSERT ON public.admissions
  FOR EACH ROW EXECUTE FUNCTION public.assign_admission_row_number();

-- ----------------------------------------------------------------------------
-- 10. Grants & RLS (centralised)
-- ----------------------------------------------------------------------------
-- Every public table: RLS on, full access for service_role, no anon access.
-- authenticated gets full DML; RLS policies below decide what is allowed.
DO $$ DECLARE t text; BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
  END LOOP;
END $$;
-- Tables written only by SECURITY DEFINER functions or the server: read-only / append-only.
REVOKE INSERT, UPDATE, DELETE ON public.numbering_counters, public.teaching_assignments FROM authenticated;
REVOKE UPDATE, DELETE ON public.finance_config_audit FROM authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.admission_number_seq, public.employee_id_seq TO service_role;

-- Function execution rights
REVOKE ALL ON FUNCTION private.has_role(uuid, public.app_role), private.is_admin(uuid),
  private.owns_admission(uuid), private.staff_teaches_class(text), private.staff_teaches_admission(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.has_role(uuid, public.app_role), private.is_admin(uuid),
  private.owns_admission(uuid), private.staff_teaches_class(text), private.staff_teaches_admission(uuid)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.next_generated_number(text), public.assign_admission_number(),
  public.assign_admission_row_number(), public.assign_employee_id(), public.set_updated_at()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_public_branding() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_branding() TO anon, authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 11. Policies
-- ----------------------------------------------------------------------------
-- Helper: (re)create a policy idempotently. Dropped at the end of the script.
CREATE OR REPLACE FUNCTION pg_temp.policy(_table text, _name text, _cmd text, _using text, _check text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', _name, _table);
  EXECUTE format('CREATE POLICY %I ON public.%I FOR %s TO authenticated', _name, _table, _cmd)
    || CASE WHEN _using IS NOT NULL THEN ' USING (' || _using || ')' ELSE '' END
    || CASE WHEN _check IS NOT NULL THEN ' WITH CHECK (' || _check || ')' ELSE '' END;
END; $$;

-- Remove superseded / redundant policies (fully covered by the ones below).
DROP POLICY IF EXISTS "super admin full access profiles" ON public.profiles;
DROP POLICY IF EXISTS "admins read offer letters" ON public.offer_letters;
DROP POLICY IF EXISTS "staff read admissions" ON public.admissions;
DROP POLICY IF EXISTS "config read" ON public.numbering_counters;
DROP POLICY IF EXISTS "config read" ON public.numbering_settings;
DROP POLICY IF EXISTS "config read" ON public.schools;
DROP POLICY IF EXISTS "config read" ON public.school_branding;

DO $$
DECLARE
  adm   constant text := 'private.is_admin(auth.uid())';
  sa    constant text := 'private.has_role(auth.uid(), ''super_admin''::public.app_role)';
  staff constant text := 'private.has_role(auth.uid(), ''staff''::public.app_role)';
  own_email constant text := 'lower(email) = lower(COALESCE((SELECT u.email FROM auth.users u WHERE u.id = auth.uid()), ''''))';
  t text;
BEGIN
  -- profiles
  PERFORM pg_temp.policy('profiles', 'own profile read', 'SELECT', 'id = auth.uid() OR ' || adm);
  PERFORM pg_temp.policy('profiles', 'own profile update', 'UPDATE', 'id = auth.uid() OR ' || adm, 'id = auth.uid() OR ' || adm);
  PERFORM pg_temp.policy('profiles', 'admins insert profiles', 'INSERT', NULL, adm);
  PERFORM pg_temp.policy('profiles', 'super admins delete profiles', 'DELETE', sa);

  -- user_roles
  PERFORM pg_temp.policy('user_roles', 'read own roles', 'SELECT', 'user_id = auth.uid() OR ' || adm);
  PERFORM pg_temp.policy('user_roles', 'super admin full access user_roles', 'ALL', sa, sa);

  -- password_reset_requests
  PERFORM pg_temp.policy('password_reset_requests', 'admins read reset requests', 'SELECT', adm);
  PERFORM pg_temp.policy('password_reset_requests', 'admins update reset requests', 'UPDATE', adm, adm);
  PERFORM pg_temp.policy('password_reset_requests', 'admins delete reset requests', 'DELETE', adm);
  PERFORM pg_temp.policy('password_reset_requests', 'super admin full access reset requests', 'ALL', sa, sa);
  PERFORM pg_temp.policy('password_reset_requests', 'users read own reset requests', 'SELECT', own_email);
  PERFORM pg_temp.policy('password_reset_requests', 'users create own reset request', 'INSERT', NULL, own_email);

  -- audit_logs
  PERFORM pg_temp.policy('audit_logs', 'admins read audit logs', 'SELECT', adm);
  PERFORM pg_temp.policy('audit_logs', 'admins insert audit logs', 'INSERT', NULL, adm);
  PERFORM pg_temp.policy('audit_logs', 'admins delete audit logs', 'DELETE', adm);
  PERFORM pg_temp.policy('audit_logs', 'super admin full access audit_logs', 'ALL', sa, sa);

  -- security_settings
  PERFORM pg_temp.policy('security_settings', 'admins read security settings', 'SELECT', adm);
  PERFORM pg_temp.policy('security_settings', 'admins insert security settings', 'INSERT', NULL, adm);
  PERFORM pg_temp.policy('security_settings', 'admins update security settings', 'UPDATE', adm, adm);
  PERFORM pg_temp.policy('security_settings', 'super admin full access security_settings', 'ALL', sa, sa);

  -- Configuration catalogue: readable by signed-in users, managed by Super Admin.
  FOREACH t IN ARRAY ARRAY['school_types','education_levels','subjects','tenant_settings'] LOOP
    PERFORM pg_temp.policy(t, 'config read', 'SELECT', 'true');
    PERFORM pg_temp.policy(t, 'super admin all', 'ALL', sa, sa);
  END LOOP;
  -- Admin-only reads (public name comes through get_public_branding()).
  FOREACH t IN ARRAY ARRAY['schools','school_branding','numbering_settings'] LOOP
    PERFORM pg_temp.policy(t, 'admins read ' || replace(t, '_', ' '), 'SELECT', adm);
    PERFORM pg_temp.policy(t, 'super admin all', 'ALL', sa, sa);
  END LOOP;
  PERFORM pg_temp.policy('numbering_counters', 'admins read numbering counters', 'SELECT', adm);
  PERFORM pg_temp.policy('school_classes', 'Signed-in users can view classes', 'SELECT', 'true');
  PERFORM pg_temp.policy('school_classes', 'Super admins manage classes', 'ALL', sa, sa);

  -- Staff
  PERFORM pg_temp.policy('staff_performance', 'staff performance readable by self or admins', 'SELECT', 'staff_id = auth.uid() OR ' || adm);
  PERFORM pg_temp.policy('staff_performance', 'admins manage staff performance', 'ALL', adm, adm);
  PERFORM pg_temp.policy('staff_schedules', 'schedules readable by self or admins', 'SELECT', 'staff_id = auth.uid() OR ' || adm);
  PERFORM pg_temp.policy('staff_schedules', 'admins manage schedules', 'ALL', adm, adm);
  PERFORM pg_temp.policy('offer_letters', 'admins manage offer letters', 'ALL', adm, adm);
  PERFORM pg_temp.policy('class_teachers', 'authenticated read class teachers', 'SELECT', 'true');
  PERFORM pg_temp.policy('class_teachers', 'admins manage class teachers', 'ALL', adm, adm);
  PERFORM pg_temp.policy('teaching_assignments', 'Signed-in users can view teaching assignments', 'SELECT', 'true');

  -- Students
  PERFORM pg_temp.policy('admissions', 'admins manage admissions', 'ALL', adm, adm);
  PERFORM pg_temp.policy('admissions', 'family reads own admissions', 'SELECT', 'parent_profile_id = auth.uid() OR student_profile_id = auth.uid()');
  PERFORM pg_temp.policy('admissions', 'staff read own class admissions', 'SELECT', staff || ' AND private.staff_teaches_class(class_admitted)');

  PERFORM pg_temp.policy('student_performance', 'admins manage performance', 'ALL', adm, adm);
  PERFORM pg_temp.policy('student_performance', 'family reads performance', 'SELECT', 'private.owns_admission(admission_id) OR ' || staff);

  PERFORM pg_temp.policy('student_attendance', 'admins manage attendance', 'ALL', adm, adm);
  PERFORM pg_temp.policy('student_attendance', 'family reads attendance', 'SELECT',
    'private.owns_admission(admission_id) OR (' || staff || ' AND private.staff_teaches_admission(admission_id))');
  PERFORM pg_temp.policy('student_attendance', 'staff record attendance', 'INSERT', NULL, staff || ' AND private.staff_teaches_admission(admission_id)');
  PERFORM pg_temp.policy('student_attendance', 'staff update attendance', 'UPDATE',
    staff || ' AND private.staff_teaches_admission(admission_id)', staff || ' AND private.staff_teaches_admission(admission_id)');

  PERFORM pg_temp.policy('student_fees', 'admins manage fees', 'ALL', adm, adm);
  PERFORM pg_temp.policy('student_fees', 'family reads fees', 'SELECT', 'private.owns_admission(admission_id)');

  PERFORM pg_temp.policy('student_exeat', 'admins manage exeat', 'ALL', adm, adm);
  PERFORM pg_temp.policy('student_exeat', 'staff manage exeat', 'ALL', staff, staff);
  PERFORM pg_temp.policy('student_exeat', 'family reads exeat', 'SELECT', 'private.owns_admission(admission_id)');

  PERFORM pg_temp.policy('student_assessments', 'admins manage assessments', 'ALL', adm, adm);
  PERFORM pg_temp.policy('student_assessments', 'staff record assessments', 'INSERT', NULL, staff);
  PERFORM pg_temp.policy('student_assessments', 'staff update assessments', 'UPDATE', staff, staff);
  PERFORM pg_temp.policy('student_assessments', 'family reads assessments', 'SELECT', 'private.owns_admission(admission_id) OR ' || staff);

  -- Finance
  FOREACH t IN ARRAY ARRAY['finance_income','finance_expenses','finance_payroll'] LOOP
    PERFORM pg_temp.policy(t, t || '_admin', 'ALL', adm, adm);
  END LOOP;
  PERFORM pg_temp.policy('finance_config_sections', 'finance config read', 'SELECT', 'true');
  PERFORM pg_temp.policy('finance_config_sections', 'finance config super admin', 'ALL', sa, sa);
  PERFORM pg_temp.policy('finance_reference_items', 'finance reference read', 'SELECT', 'true');
  PERFORM pg_temp.policy('finance_reference_items', 'finance reference super admin', 'ALL', sa, sa);
  PERFORM pg_temp.policy('finance_rules', 'finance rules read', 'SELECT', 'true');
  PERFORM pg_temp.policy('finance_rules', 'finance rules super admin', 'ALL', sa, sa);
  PERFORM pg_temp.policy('finance_config_audit', 'finance audit read', 'SELECT', sa);
  PERFORM pg_temp.policy('finance_config_audit', 'finance audit insert', 'INSERT', NULL, sa);
END $$;

DROP FUNCTION pg_temp.policy(text, text, text, text, text);

-- ----------------------------------------------------------------------------
-- 12. Reference seed data (never overwrites edits)
-- ----------------------------------------------------------------------------
INSERT INTO public.security_settings (singleton) VALUES (true) ON CONFLICT (singleton) DO NOTHING;

INSERT INTO public.school_types (code, name, description) VALUES
  ('public','Public / Government','State funded, national curriculum.'),
  ('private','Private / Independent','Privately funded, own fee structure.'),
  ('international','International','IB, Cambridge or multi-curriculum.'),
  ('faith','Faith-based','Mission or religious foundation.'),
  ('special','Special Needs','Inclusive and assisted learning.'),
  ('online','Online / Virtual','Fully remote delivery.'),
  ('vocational','Vocational Institute','Skills and trade certification.')
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.education_levels (code, name, sort_order, min_age, max_age) VALUES
  ('early-years','Early Years / Nursery',1,2,5),
  ('primary','Primary / Elementary',2,6,11),
  ('junior-secondary','Junior Secondary / Middle',3,12,14),
  ('senior-secondary','Senior Secondary / High',4,15,18),
  ('tvet','Technical & Vocational (TVET)',5,NULL,NULL),
  ('tertiary','Tertiary / University',6,NULL,NULL),
  ('continuing','Continuing & Professional Education',7,NULL,NULL)
ON CONFLICT (code) DO NOTHING;

COMMIT;
