-- Home base: public forms, events, the teachers' journal, the social calendar
-- and the audience list. Same rules as the club:
--   * Nothing is readable or writable by the API roles except through the
--     functions in the next migration (leads are the one table staff may read
--     directly, so the inbox can update live).
--   * People who are not signed in can do exactly seven things, all
--     rate-limited: send a form, sign up for an event, read published events,
--     read the published journal and teachers, and unsubscribe.

-- ── teachers ──────────────────────────────────────────────────────────────
-- A teacher is someone with a sign-in who may write journal posts. Staff add
-- them by email after the teacher has signed in once.
create table public.teachers (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  bio          text check (bio is null or char_length(bio) <= 600),
  photo_url    text check (photo_url is null or (photo_url ~ '^https://' and char_length(photo_url) <= 500)),
  created_at   timestamptz not null default now()
);
alter table public.teachers enable row level security;   -- no policies: functions only

create or replace function public.is_teacher() returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.teachers where user_id = (select auth.uid())) $$;

-- ── events ────────────────────────────────────────────────────────────────
create table public.events (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(btrim(title)) between 1 and 80),
  blurb       text not null default '' check (char_length(blurb) <= 600),
  starts_at   timestamptz not null,
  ends_at     timestamptz check (ends_at is null or ends_at >= starts_at),
  location    text not null default 'Gilbert Flex Studio' check (char_length(location) <= 120),
  price_text  text check (price_text is null or char_length(price_text) <= 40),
  spots       integer check (spots is null or spots between 1 and 500),
  booking_url text check (booking_url is null or (booking_url ~ '^https://' and char_length(booking_url) <= 500)),
  host_name   text check (host_name is null or char_length(host_name) <= 60),
  published   boolean not null default false,
  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index events_starts_at on public.events (starts_at);
alter table public.events enable row level security;

-- ── leads: every form and sign-up lands here ──────────────────────────────
create table public.leads (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null unique,          -- made by the page, so a retry is not a second lead
  kind           text not null check (kind in ('event_request', 'partner_request', 'signup', 'event_signup')),
  name           text not null check (char_length(btrim(name)) between 1 and 60),
  contact        text not null check (char_length(contact) between 5 and 120),
  contact_norm   text not null,
  email          text,
  phone          text,
  fields         jsonb not null default '{}'::jsonb check (jsonb_typeof(fields) = 'object' and char_length(fields::text) <= 4000),
  consent        boolean not null default false,  -- agreed to hear from the studio
  source         text check (source is null or source ~ '^[A-Za-z0-9_-]{1,40}$'),
  event_id       uuid references public.events (id) on delete cascade,
  status         text not null default 'new' check (status in ('new', 'seen', 'done', 'spam')),
  note           text check (note is null or char_length(note) <= 1000),
  attended       boolean,                         -- set at the door for event sign-ups
  handled_by     uuid references auth.users (id) on delete set null,
  unsub_token    uuid not null default gen_random_uuid() unique,
  unsubscribed_at timestamptz,
  created_at     timestamptz not null default now(),
  check ((kind = 'event_signup') = (event_id is not null))
);
create index leads_inbox on public.leads (status, created_at desc);
create index leads_created on public.leads (created_at desc);
create index leads_contact_time on public.leads (contact_norm, created_at desc);
create index leads_event on public.leads (event_id) where event_id is not null;
create unique index leads_one_signup_per_event on public.leads (event_id, contact_norm) where kind = 'event_signup';
alter table public.leads enable row level security;
create policy leads_staff_read on public.leads for select to authenticated
  using ((select public.is_staff()));

-- ── the journal ───────────────────────────────────────────────────────────
create table public.journal_posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references auth.users (id) on delete cascade,
  author_name text not null check (char_length(author_name) between 1 and 60),
  client_id   uuid not null,
  kind        text not null default 'post' check (kind in ('post', 'teacher_of_week', 'event_of_week')),
  title       text not null check (char_length(btrim(title)) between 1 and 100),
  body        text not null check (char_length(btrim(body)) between 1 and 20000),
  cover_url   text check (cover_url is null or (cover_url ~ '^https://' and char_length(cover_url) <= 500)),
  slug        text unique,
  status      text not null default 'draft' check (status in ('draft', 'submitted', 'published', 'rejected')),
  review_note text check (review_note is null or char_length(review_note) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  published_at timestamptz,
  unique (author_id, client_id),
  check ((status = 'published') = (published_at is not null))
);
create index journal_public on public.journal_posts (published_at desc) where status = 'published';
create index journal_author on public.journal_posts (author_id, updated_at desc);
create index journal_review on public.journal_posts (status, updated_at desc);
alter table public.journal_posts enable row level security;

-- ── the social calendar ───────────────────────────────────────────────────
-- A plan of what to post and when. Posting itself happens in Instagram; the
-- studio marks a post "posted" once it is out. No Instagram login is stored.
create table public.social_posts (
  id           uuid primary key default gen_random_uuid(),
  scheduled_for timestamptz not null,
  kind         text not null default 'feed' check (kind in ('feed', 'story', 'reel')),
  caption      text not null default '' check (char_length(caption) <= 2200),
  image_url    text check (image_url is null or (image_url ~ '^https://' and char_length(image_url) <= 500)),
  status       text not null default 'idea' check (status in ('idea', 'draft', 'approved', 'posted')),
  event_id     uuid references public.events (id) on delete set null,
  journal_post_id uuid references public.journal_posts (id) on delete set null,
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now()
);
create index social_when on public.social_posts (scheduled_for);
alter table public.social_posts enable row level security;

-- ── access: nothing by default ────────────────────────────────────────────
revoke all on public.teachers, public.events, public.leads, public.journal_posts, public.social_posts from anon, authenticated;
grant select on public.leads to authenticated;            -- rows are limited to staff by the policy above

-- Staff see new leads arrive without refreshing, where Realtime exists.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.leads;
  end if;
end $$;

-- Photos for the journal and teachers: a public bucket where each teacher can
-- only write inside a folder named after their own user id. Only runs on a
-- project that has Storage.
do $$ begin
  if to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null then
    insert into storage.buckets (id, name, public) values ('journal', 'journal', true) on conflict (id) do nothing;
    execute $p$create policy journal_photos_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'journal' and (select public.is_staff() or public.is_teacher())
                  and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
    execute $p$create policy journal_photos_update on storage.objects for update to authenticated
      using (bucket_id = 'journal' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
    execute $p$create policy journal_photos_delete on storage.objects for delete to authenticated
      using (bucket_id = 'journal' and (storage.foldername(name))[1] = (select auth.uid())::text)$p$;
  end if;
end $$;
