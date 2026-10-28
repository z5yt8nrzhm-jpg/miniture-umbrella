-- Demo data for local development only. `supabase db reset` loads this.
-- The classes are placed around "now" so check-in works the moment you start.
-- Codes: MAT222 (open now), FLOW33 (starts in 30 minutes), REST44 (ended earlier today).

with t as (
  insert into public.classes (class_type, starts_at, duration_min, instructor, capacity) values
    ('mat_pilates', now() - interval '10 minutes', 50, 'Mia',  12),
    ('yoga_flow',   now() + interval '30 minutes', 60, 'Jess', 14),
    ('stretch',     now() - interval '4 hours',    45, 'Mia',  16)
  returning id, class_type
)
insert into public.class_codes (class_id, code)
select id, case class_type when 'mat_pilates' then 'MAT222' when 'yoga_flow' then 'FLOW33' else 'REST44' end from t;
