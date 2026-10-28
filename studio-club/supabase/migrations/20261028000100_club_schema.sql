-- Gilbert Flex Studio members club: tables, privacy rules and indexes.
--
-- Design rules, so the club stays safe on a flaky phone connection:
--   * Members never write to tables directly. Every write goes through a
--     function in 20261028000200_club_functions.sql, which enforces the
--     rules and is safe to retry.
--   * Row level security is on for every table, and the API roles get only
--     the SELECT access written below. Nothing is granted by default.
--   * Private things (check-in codes, member numbers, other members'
--     history) are never readable by another member.

-- The studio's clock. Weeks, "today" and streaks all follow it. Phoenix has
-- no daylight saving, so a class never shifts by an hour.
create or replace function public.club_tz() returns text
language sql immutable parallel safe set search_path = ''
as $$ select 'America/Phoenix'::text $$;

-- ── staff ─────────────────────────────────────────────────────────────────
-- Add a staff member from the SQL editor:
--   insert into public.staff (user_id) select id from auth.users where email = 'you@example.com';
create table public.staff (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.staff enable row level security;   -- no policies: only the dashboard can edit

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.staff where user_id = (select auth.uid())) $$;

-- ── members ───────────────────────────────────────────────────────────────
create sequence public.member_number_seq start 1001;

create table public.profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  member_number  integer not null unique default nextval('public.member_number_seq'),
  display_name   text not null check (char_length(btrim(display_name)) between 1 and 30),
  favorite_class text check (favorite_class is null or char_length(favorite_class) <= 40),
  avatar         text not null default 'sage' check (avatar in ('sage', 'clay', 'gold', 'sky', 'rose')),
  created_at     timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy profiles_read_own on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_staff()));

-- ── the schedule ──────────────────────────────────────────────────────────
create table public.class_types (
  code  text primary key check (code ~ '^[a-z0-9_]{2,30}$'),
  name  text not null,
  pace  text not null check (pace in ('calm', 'steady', 'energetic')),
  blurb text not null default '',
  sort  integer not null default 0
);
alter table public.class_types enable row level security;
create policy class_types_read on public.class_types for select to authenticated using (true);

create table public.classes (
  id           uuid primary key default gen_random_uuid(),
  class_type   text not null references public.class_types (code),
  starts_at    timestamptz not null,
  duration_min integer not null default 50 check (duration_min between 15 and 180),
  instructor   text not null check (char_length(btrim(instructor)) between 1 and 40),
  capacity     integer check (capacity is null or capacity between 1 and 200),
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index classes_starts_at on public.classes (starts_at);
alter table public.classes enable row level security;
create policy classes_read on public.classes for select to authenticated using (true);

-- The check-in code lives in its own table so members can read the schedule
-- but never the code.
create table public.class_codes (
  class_id uuid primary key references public.classes (id) on delete cascade,
  code     text not null unique check (code ~ '^[A-Z2-9]{6}$')
);
alter table public.class_codes enable row level security;
create policy class_codes_staff on public.class_codes for select to authenticated
  using ((select public.is_staff()));

-- ── check-ins ─────────────────────────────────────────────────────────────
create table public.checkins (
  id            uuid primary key default gen_random_uuid(),
  member_id     uuid not null references public.profiles (id) on delete cascade,
  class_id      uuid not null references public.classes (id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  unique (member_id, class_id)          -- a retry or double-tap can never count twice
);
create index checkins_member_time on public.checkins (member_id, checked_in_at desc);
create index checkins_class on public.checkins (class_id);
alter table public.checkins enable row level security;
create policy checkins_read on public.checkins for select to authenticated
  using (member_id = (select auth.uid()) or (select public.is_staff()));

-- Failed code attempts, so a code can't be guessed by hammering the screen.
create table public.checkin_attempts (
  id        bigint generated always as identity primary key,
  member_id uuid not null references public.profiles (id) on delete cascade,
  at        timestamptz not null default now()
);
create index checkin_attempts_member_time on public.checkin_attempts (member_id, at desc);
alter table public.checkin_attempts enable row level security;   -- no policies

-- ── badges and perks ──────────────────────────────────────────────────────
create table public.badges (
  code      text primary key check (code ~ '^[a-z0-9_]{2,30}$'),
  title     text not null,
  blurb     text not null,
  kind      text not null check (kind in ('classes', 'streak')),
  threshold integer not null check (threshold > 0),
  sort      integer not null default 0
);
alter table public.badges enable row level security;
create policy badges_read on public.badges for select to authenticated using (true);

create table public.member_badges (
  member_id  uuid not null references public.profiles (id) on delete cascade,
  badge_code text not null references public.badges (code),
  earned_at  timestamptz not null default now(),
  primary key (member_id, badge_code)
);
alter table public.member_badges enable row level security;
create policy member_badges_read on public.member_badges for select to authenticated
  using (member_id = (select auth.uid()) or (select public.is_staff()));

create table public.perks (
  code             text primary key check (code ~ '^[a-z0-9_]{2,30}$'),
  title            text not null,
  blurb            text not null,
  required_classes integer not null check (required_classes > 0),
  sort             integer not null default 0
);
alter table public.perks enable row level security;
create policy perks_read on public.perks for select to authenticated using (true);

create table public.member_perks (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.profiles (id) on delete cascade,
  perk_code   text not null references public.perks (code),
  earned_at   timestamptz not null default now(),
  redeemed_at timestamptz,
  redeemed_by uuid references auth.users (id) on delete set null,
  unique (member_id, perk_code)
);
alter table public.member_perks enable row level security;
create policy member_perks_read on public.member_perks for select to authenticated
  using (member_id = (select auth.uid()) or (select public.is_staff()));

-- ── the community wall ────────────────────────────────────────────────────
create table public.wall_posts (
  id            uuid primary key default gen_random_uuid(),
  author_id     uuid not null references public.profiles (id) on delete cascade,
  client_id     uuid not null,          -- made on the phone, so a retried post is not a second post
  body          text not null check (char_length(btrim(body)) between 1 and 500),
  created_at    timestamptz not null default now(),
  hidden        boolean not null default false,
  hidden_reason text,
  unique (author_id, client_id)
);
create index wall_posts_feed on public.wall_posts (created_at desc, id desc) where not hidden;
create index wall_posts_author_time on public.wall_posts (author_id, created_at desc);
alter table public.wall_posts enable row level security;
create policy wall_posts_staff_read on public.wall_posts for select to authenticated
  using ((select public.is_staff()));

create table public.wall_cheers (
  post_id    uuid not null references public.wall_posts (id) on delete cascade,
  member_id  uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, member_id)
);
create index wall_cheers_member on public.wall_cheers (member_id);
alter table public.wall_cheers enable row level security;        -- no policies

create table public.wall_reports (
  post_id     uuid not null references public.wall_posts (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, reporter_id)
);
create index wall_reports_reporter on public.wall_reports (reporter_id);
alter table public.wall_reports enable row level security;
create policy wall_reports_staff_read on public.wall_reports for select to authenticated
  using ((select public.is_staff()));

-- ── access: nothing by default, then exactly what members need ───────────
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

grant select on
  public.profiles, public.class_types, public.classes, public.class_codes,
  public.checkins, public.badges, public.member_badges, public.perks,
  public.member_perks, public.wall_posts, public.wall_reports
to authenticated;
