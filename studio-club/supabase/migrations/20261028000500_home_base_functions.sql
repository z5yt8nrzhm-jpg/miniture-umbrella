-- Functions for the home base. Every one returns a plain status instead of
-- raising, so a retry on a bad connection is always safe.

-- ── small helpers (not callable by the API) ───────────────────────────────
create or replace function public._slugify(p text) returns text
language sql immutable set search_path = ''
as $$ select left(btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g'), '-'), 60) $$;

create or replace function public._require_writer() returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.is_staff() or public.is_teacher()) then raise exception 'not_writer' using errcode = '42501'; end if;
end $$;

create or replace function public._looks_like_contact(p text) returns boolean
language sql immutable set search_path = ''
as $$ select p ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) between 7 and 15 $$;

-- ═══ PUBLIC (signed out) ═══════════════════════════════════════════════════

-- Anyone can send a form. Bots are caught by a hidden field (p_trap) and a
-- limit of 5 per contact per hour and 300 per hour overall.
create or replace function public.submit_form(
  p_client_id uuid, p_kind text, p_name text, p_contact text,
  p_fields jsonb default '{}'::jsonb, p_consent boolean default false,
  p_source text default null, p_trap text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_contact text := btrim(coalesce(p_contact, '')); v_norm text := lower(btrim(coalesce(p_contact, '')));
        v_src text := nullif(left(regexp_replace(coalesce(p_source, ''), '[^A-Za-z0-9_-]', '', 'g'), 40), '');
begin
  if btrim(coalesce(p_trap, '')) <> '' then return jsonb_build_object('status', 'ok'); end if;   -- a bot; look happy, store nothing
  if p_client_id is null or p_kind is null or p_kind not in ('event_request', 'partner_request', 'signup')
     or char_length(btrim(coalesce(p_name, ''))) not between 1 and 60
     or not public._looks_like_contact(v_contact) or char_length(v_contact) > 120
     or p_fields is null or jsonb_typeof(p_fields) <> 'object' or char_length(p_fields::text) > 4000
  then return jsonb_build_object('status', 'invalid'); end if;

  perform pg_advisory_xact_lock(hashtextextended('lead:' || v_norm, 0));
  if exists (select 1 from public.leads where client_id = p_client_id) then return jsonb_build_object('status', 'ok'); end if;
  if (select count(*) from public.leads where contact_norm = v_norm and created_at > now() - interval '1 hour') >= 5
    then return jsonb_build_object('status', 'rate_limited'); end if;
  if (select count(*) from public.leads where created_at > now() - interval '1 hour') >= 300
    then return jsonb_build_object('status', 'busy'); end if;

  insert into public.leads (client_id, kind, name, contact, contact_norm, email, phone, fields, consent, source)
  values (p_client_id, p_kind, btrim(p_name), v_contact, v_norm,
          case when v_contact like '%@%' then v_norm end, case when v_contact not like '%@%' then v_contact end,
          p_fields, coalesce(p_consent, false), v_src)
  on conflict (client_id) do nothing;
  return jsonb_build_object('status', 'ok');
end $$;

-- Sign up for an event. Spots are counted under a lock, so two people can
-- never take the last one.
create or replace function public.event_signup(
  p_client_id uuid, p_event_id uuid, p_name text, p_contact text,
  p_consent boolean default false, p_source text default null, p_trap text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_contact text := btrim(coalesce(p_contact, '')); v_norm text := lower(btrim(coalesce(p_contact, '')));
        v_src text := nullif(left(regexp_replace(coalesce(p_source, ''), '[^A-Za-z0-9_-]', '', 'g'), 40), '');
        e public.events;
begin
  if btrim(coalesce(p_trap, '')) <> '' then return jsonb_build_object('status', 'ok'); end if;
  if p_client_id is null or p_event_id is null or char_length(btrim(coalesce(p_name, ''))) not between 1 and 60
     or not public._looks_like_contact(v_contact) or char_length(v_contact) > 120
  then return jsonb_build_object('status', 'invalid'); end if;

  perform pg_advisory_xact_lock(hashtextextended('event:' || p_event_id::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('lead:' || v_norm, 0));
  if exists (select 1 from public.leads where client_id = p_client_id) then return jsonb_build_object('status', 'ok'); end if;
  select * into e from public.events where id = p_event_id;
  if not found or not e.published or coalesce(e.ends_at, e.starts_at) < now() then return jsonb_build_object('status', 'closed'); end if;
  if exists (select 1 from public.leads where event_id = p_event_id and contact_norm = v_norm and kind = 'event_signup')
    then return jsonb_build_object('status', 'ok'); end if;                                   -- already on the list
  if (select count(*) from public.leads where contact_norm = v_norm and created_at > now() - interval '1 hour') >= 5
    then return jsonb_build_object('status', 'rate_limited'); end if;
  if (select count(*) from public.leads where created_at > now() - interval '1 hour') >= 300
    then return jsonb_build_object('status', 'busy'); end if;
  if e.spots is not null and (select count(*) from public.leads where event_id = p_event_id and kind = 'event_signup' and status <> 'spam') >= e.spots
    then return jsonb_build_object('status', 'full'); end if;

  insert into public.leads (client_id, kind, name, contact, contact_norm, email, phone, consent, source, event_id)
  values (p_client_id, 'event_signup', btrim(p_name), v_contact, v_norm,
          case when v_contact like '%@%' then v_norm end, case when v_contact not like '%@%' then v_contact end,
          coalesce(p_consent, false), v_src, p_event_id)
  on conflict (client_id) do nothing;
  return jsonb_build_object('status', 'ok');
end $$;

-- Upcoming published events, with how many spots are left (never who signed up).
create or replace function public.public_events() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'title', e.title, 'blurb', e.blurb, 'starts_at', e.starts_at, 'ends_at', e.ends_at,
    'location', e.location, 'price', e.price_text, 'host', e.host_name, 'booking_url', e.booking_url,
    'spots_left', case when e.spots is null then null else greatest(e.spots - s.n, 0) end) order by e.starts_at), '[]'::jsonb)
  from public.events e
  cross join lateral (select count(*)::int n from public.leads l where l.event_id = e.id and l.kind = 'event_signup' and l.status <> 'spam') s
  where e.published and coalesce(e.ends_at, e.starts_at) >= now()
$$;

create or replace function public.public_journal(p_limit integer default 10, p_before timestamptz default null) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x ->> 'published_at') desc), '[]'::jsonb) from (
    select jsonb_build_object('slug', slug, 'kind', kind, 'title', title, 'excerpt', left(body, 220),
           'author', author_name, 'cover_url', cover_url, 'published_at', published_at) x
    from public.journal_posts
    where status = 'published' and (p_before is null or published_at < p_before)
    order by published_at desc limit least(greatest(coalesce(p_limit, 10), 1), 30)) t
$$;

create or replace function public.public_post(p_slug text) returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('slug', slug, 'kind', kind, 'title', title, 'body', body, 'author', author_name,
         'cover_url', cover_url, 'published_at', published_at)
  from public.journal_posts where status = 'published' and slug = p_slug
$$;

create or replace function public.public_teachers() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', display_name, 'bio', bio, 'photo_url', photo_url) order by display_name), '[]'::jsonb)
  from public.teachers
$$;

-- The link at the bottom of every email we send.
create or replace function public.unsubscribe(p_token uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_norm text;
begin
  select contact_norm into v_norm from public.leads where unsub_token = p_token;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  update public.leads set unsubscribed_at = coalesce(unsubscribed_at, now()) where contact_norm = v_norm;   -- every record of that contact
  return jsonb_build_object('status', 'ok');
end $$;

-- ═══ ANY SIGNED-IN WRITER (teacher or staff) ═══════════════════════════════

create or replace function public.my_role() returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('staff', public.is_staff(), 'teacher', public.is_teacher(),
    'name', coalesce((select display_name from public.teachers where user_id = (select auth.uid())),
                     (select display_name from public.profiles where id = (select auth.uid()))))
$$;

create or replace function public.teacher_save_profile(p_name text, p_bio text default null, p_photo text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_teacher() then raise exception 'not_teacher' using errcode = '42501'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 40 or char_length(coalesce(p_bio, '')) > 600
     or (p_photo is not null and (p_photo !~ '^https://' or char_length(p_photo) > 500))
  then return jsonb_build_object('status', 'invalid'); end if;
  update public.teachers set display_name = btrim(p_name), bio = nullif(btrim(p_bio), ''), photo_url = p_photo
   where user_id = (select auth.uid());
  return jsonb_build_object('status', 'ok');
end $$;

-- Create or edit a draft. A retry with the same client id returns the same post.
create or replace function public.post_save(p_client_id uuid, p_id uuid, p_kind text, p_title text, p_body text, p_cover text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare me uuid := (select auth.uid()); v_name text; r public.journal_posts;
begin
  perform public._require_writer();
  if p_kind is null or p_kind not in ('post', 'teacher_of_week', 'event_of_week')
     or char_length(btrim(coalesce(p_title, ''))) not between 1 and 100
     or char_length(btrim(coalesce(p_body, ''))) not between 1 and 20000
     or (p_cover is not null and (p_cover !~ '^https://' or char_length(p_cover) > 500))
  then return jsonb_build_object('status', 'invalid'); end if;

  if p_id is null then
    if p_client_id is null then return jsonb_build_object('status', 'invalid'); end if;
    select * into r from public.journal_posts where author_id = me and client_id = p_client_id;
    if found then return jsonb_build_object('status', 'ok', 'id', r.id); end if;
    v_name := coalesce((select display_name from public.teachers where user_id = me),
                       (select display_name from public.profiles where id = me), 'Gilbert Flex Studio');
    insert into public.journal_posts (author_id, author_name, client_id, kind, title, body, cover_url)
    values (me, v_name, p_client_id, p_kind, btrim(p_title), btrim(p_body), p_cover)
    on conflict (author_id, client_id) do nothing returning * into r;
    if r.id is null then select * into r from public.journal_posts where author_id = me and client_id = p_client_id; end if;
    return jsonb_build_object('status', 'ok', 'id', r.id);
  end if;

  select * into r from public.journal_posts where id = p_id for update;
  if not found or (r.author_id <> me and not public.is_staff()) then return jsonb_build_object('status', 'not_found'); end if;
  if r.status = 'published' and not public.is_staff() then return jsonb_build_object('status', 'locked'); end if;
  update public.journal_posts set kind = p_kind, title = btrim(p_title), body = btrim(p_body), cover_url = p_cover, updated_at = now(),
         status = case when r.status in ('submitted', 'rejected') then 'draft' else r.status end, review_note = null
   where id = p_id;
  return jsonb_build_object('status', 'ok', 'id', p_id);
end $$;

create or replace function public.post_submit(p_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r public.journal_posts;
begin
  perform public._require_writer();
  select * into r from public.journal_posts where id = p_id for update;
  if not found or (r.author_id <> (select auth.uid()) and not public.is_staff()) then return jsonb_build_object('status', 'not_found'); end if;
  if r.status = 'submitted' then return jsonb_build_object('status', 'ok'); end if;          -- a retry
  if r.status not in ('draft', 'rejected') then return jsonb_build_object('status', 'invalid_state'); end if;
  update public.journal_posts set status = 'submitted', review_note = null, updated_at = now() where id = p_id;
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.post_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare r public.journal_posts;
begin
  perform public._require_writer();
  select * into r from public.journal_posts where id = p_id;
  if not found or (r.author_id <> (select auth.uid()) and not public.is_staff()) then return null; end if;
  return jsonb_build_object('id', r.id, 'kind', r.kind, 'title', r.title, 'body', r.body, 'cover_url', r.cover_url,
    'status', r.status, 'review_note', r.review_note, 'author', r.author_name, 'slug', r.slug, 'updated_at', r.updated_at);
end $$;

-- A writer's own posts; staff see everyone's.
create or replace function public.my_posts() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_writer();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'title', title, 'status', status,
            'review_note', review_note, 'author', author_name, 'updated_at', updated_at, 'slug', slug) order by updated_at desc), '[]'::jsonb)
          from public.journal_posts where author_id = (select auth.uid()) or public.is_staff());
end $$;

-- ═══ STAFF ═════════════════════════════════════════════════════════════════

create or replace function public.staff_review_post(p_id uuid, p_decision text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r public.journal_posts;
begin
  perform public._require_staff();
  if p_decision not in ('publish', 'reject', 'unpublish') or char_length(coalesce(p_note, '')) > 500
    then return jsonb_build_object('status', 'invalid'); end if;
  select * into r from public.journal_posts where id = p_id for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  if p_decision = 'publish' then
    if r.status = 'published' then return jsonb_build_object('status', 'ok', 'slug', r.slug); end if;      -- a retry
    update public.journal_posts set status = 'published', published_at = now(), review_note = null, updated_at = now(),
           slug = coalesce(slug, public._slugify(title) || '-' || substr(id::text, 1, 6)) where id = p_id returning slug into r.slug;
    return jsonb_build_object('status', 'ok', 'slug', r.slug);
  elsif p_decision = 'reject' then
    if r.status = 'published' then return jsonb_build_object('status', 'invalid_state'); end if;
    update public.journal_posts set status = 'rejected', review_note = nullif(btrim(p_note), ''), updated_at = now() where id = p_id;
  else
    update public.journal_posts set status = 'draft', published_at = null, updated_at = now() where id = p_id;
  end if;
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.staff_add_teacher(p_email text, p_name text, p_bio text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_user uuid;
begin
  perform public._require_staff();
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 40 or char_length(coalesce(p_bio, '')) > 600
    then return jsonb_build_object('status', 'invalid'); end if;
  select id into v_user from auth.users where lower(email) = lower(btrim(coalesce(p_email, '')));
  if not found then return jsonb_build_object('status', 'no_such_user'); end if;       -- they must sign in once first
  insert into public.teachers (user_id, display_name, bio) values (v_user, btrim(p_name), nullif(btrim(p_bio), ''))
  on conflict (user_id) do update set display_name = excluded.display_name, bio = coalesce(excluded.bio, public.teachers.bio);
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.staff_teachers() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('user_id', t.user_id, 'name', t.display_name, 'email', u.email, 'bio', t.bio)
            order by t.display_name), '[]'::jsonb) from public.teachers t join auth.users u on u.id = t.user_id);
end $$;

create or replace function public.staff_remove_teacher(p_user uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  delete from public.teachers where user_id = p_user;
  return jsonb_build_object('status', 'ok');
end $$;

-- events
create or replace function public.staff_save_event(
  p_id uuid, p_title text, p_blurb text, p_starts timestamptz, p_ends timestamptz default null, p_location text default null,
  p_price text default null, p_spots integer default null, p_booking_url text default null, p_host text default null,
  p_published boolean default false) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  perform public._require_staff();
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 80 or p_starts is null or (p_ends is not null and p_ends < p_starts)
     or char_length(coalesce(p_blurb, '')) > 600 or char_length(coalesce(p_location, '')) > 120 or char_length(coalesce(p_price, '')) > 40
     or (p_spots is not null and p_spots not between 1 and 500) or char_length(coalesce(p_host, '')) > 60
     or (p_booking_url is not null and (p_booking_url !~ '^https://' or char_length(p_booking_url) > 500))
  then return jsonb_build_object('status', 'invalid'); end if;
  if p_id is null then
    insert into public.events (title, blurb, starts_at, ends_at, location, price_text, spots, booking_url, host_name, published, created_by)
    values (btrim(p_title), coalesce(p_blurb, ''), p_starts, p_ends, coalesce(nullif(btrim(p_location), ''), 'Gilbert Flex Studio'),
            nullif(btrim(p_price), ''), p_spots, p_booking_url, nullif(btrim(p_host), ''), coalesce(p_published, false), (select auth.uid()))
    returning id into v_id;
  else
    update public.events set title = btrim(p_title), blurb = coalesce(p_blurb, ''), starts_at = p_starts, ends_at = p_ends,
           location = coalesce(nullif(btrim(p_location), ''), 'Gilbert Flex Studio'), price_text = nullif(btrim(p_price), ''), spots = p_spots,
           booking_url = p_booking_url, host_name = nullif(btrim(p_host), ''), published = coalesce(p_published, false)
     where id = p_id returning id into v_id;
    if v_id is null then return jsonb_build_object('status', 'not_found'); end if;
  end if;
  return jsonb_build_object('status', 'ok', 'id', v_id);
end $$;

create or replace function public.staff_events() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'blurb', e.blurb, 'starts_at', e.starts_at,
      'ends_at', e.ends_at, 'location', e.location, 'price', e.price_text, 'spots', e.spots, 'booking_url', e.booking_url,
      'host', e.host_name, 'published', e.published, 'signups', s.n, 'attended', s.a) order by e.starts_at desc), '[]'::jsonb)
    from public.events e cross join lateral (
      select count(*) filter (where l.status <> 'spam')::int n, count(*) filter (where l.attended)::int a
      from public.leads l where l.event_id = e.id and l.kind = 'event_signup') s);
end $$;

create or replace function public.staff_delete_event(p_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  if exists (select 1 from public.leads where event_id = p_id) then
    update public.events set published = false where id = p_id;           -- people signed up: keep the record, just hide it
    return jsonb_build_object('status', 'hidden');
  end if;
  delete from public.events where id = p_id;
  return jsonb_build_object('status', case when found then 'ok' else 'not_found' end);
end $$;

-- the inbox
create or replace function public.staff_inbox(p_status text default 'new', p_kinds text[] default null, p_limit integer default 50, p_before timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(x order by (x ->> 'created_at') desc), '[]'::jsonb) from (
    select jsonb_build_object('id', l.id, 'kind', l.kind, 'name', l.name, 'contact', l.contact, 'fields', l.fields, 'consent', l.consent,
      'source', l.source, 'status', l.status, 'note', l.note, 'attended', l.attended, 'event_title', e.title,
      'unsubscribed', l.unsubscribed_at is not null, 'created_at', l.created_at) x
    from public.leads l left join public.events e on e.id = l.event_id
    where (p_status is null or l.status = p_status) and (p_kinds is null or l.kind = any(p_kinds))
      and (p_before is null or l.created_at < p_before)
    order by l.created_at desc limit least(greatest(coalesce(p_limit, 50), 1), 200)) t);
end $$;

create or replace function public.staff_inbox_counts() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select jsonb_build_object('new', count(*) filter (where status = 'new'), 'total', count(*)) from public.leads);
end $$;

create or replace function public.staff_lead_set(p_lead uuid, p_status text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  if p_status not in ('new', 'seen', 'done', 'spam') or char_length(coalesce(p_note, '')) > 1000 then return jsonb_build_object('status', 'invalid'); end if;
  update public.leads set status = p_status, note = coalesce(nullif(btrim(p_note), ''), note), handled_by = (select auth.uid()) where id = p_lead;
  return jsonb_build_object('status', case when found then 'ok' else 'not_found' end);
end $$;

create or replace function public.staff_mark_attended(p_lead uuid, p_attended boolean) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  update public.leads set attended = p_attended where id = p_lead and kind = 'event_signup';
  return jsonb_build_object('status', case when found then 'ok' else 'not_found' end);
end $$;

create or replace function public.staff_event_signups(p_event uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'contact', contact, 'consent', consent, 'status', status,
            'attended', attended, 'created_at', created_at) order by created_at), '[]'::jsonb)
          from public.leads where event_id = p_event and kind = 'event_signup');
end $$;

-- social calendar
create or replace function public.staff_social_save(p_id uuid, p_when timestamptz, p_kind text, p_caption text, p_image text default null,
  p_status text default 'idea', p_event uuid default null, p_journal uuid default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  perform public._require_staff();
  if p_when is null or p_kind not in ('feed', 'story', 'reel') or p_status not in ('idea', 'draft', 'approved', 'posted')
     or char_length(coalesce(p_caption, '')) > 2200 or (p_image is not null and (p_image !~ '^https://' or char_length(p_image) > 500))
  then return jsonb_build_object('status', 'invalid'); end if;
  if p_id is null then
    insert into public.social_posts (scheduled_for, kind, caption, image_url, status, event_id, journal_post_id, created_by)
    values (p_when, p_kind, coalesce(p_caption, ''), p_image, p_status, p_event, p_journal, (select auth.uid())) returning id into v_id;
  else
    update public.social_posts set scheduled_for = p_when, kind = p_kind, caption = coalesce(p_caption, ''), image_url = p_image,
           status = p_status, event_id = p_event, journal_post_id = p_journal where id = p_id returning id into v_id;
    if v_id is null then return jsonb_build_object('status', 'not_found'); end if;
  end if;
  return jsonb_build_object('status', 'ok', 'id', v_id);
end $$;

create or replace function public.staff_social_list(p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'when', s.scheduled_for, 'kind', s.kind, 'caption', s.caption,
            'image_url', s.image_url, 'status', s.status, 'event_title', e.title) order by s.scheduled_for), '[]'::jsonb)
          from public.social_posts s left join public.events e on e.id = s.event_id
          where (p_from is null or s.scheduled_for >= p_from) and (p_to is null or s.scheduled_for < p_to));
end $$;

create or replace function public.staff_social_delete(p_id uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  delete from public.social_posts where id = p_id;
  return jsonb_build_object('status', case when found then 'ok' else 'not_found' end);
end $$;

-- audience: people who said yes to hearing from the studio, never anyone who unsubscribed
create or replace function public.staff_audience(p_segment text default 'consented', p_event uuid default null, p_days integer default 90) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  if p_segment not in ('consented', 'recent', 'event_signed', 'event_attended', 'partners') then return jsonb_build_object('status', 'invalid'); end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'email', email, 'phone', phone, 'kind', kind, 'source', source,
            'created_at', created_at) order by created_at desc), '[]'::jsonb) from (
    select distinct on (contact_norm) name, email, phone, kind, source, created_at, contact_norm
    from public.leads
    where consent and unsubscribed_at is null and status <> 'spam'
      and case p_segment
            when 'consented'      then true
            when 'recent'         then created_at > now() - make_interval(days => least(greatest(coalesce(p_days, 90), 1), 3650))
            when 'event_signed'   then event_id = p_event
            when 'event_attended' then event_id = p_event and attended
            when 'partners'       then kind = 'partner_request' end
    order by contact_norm, created_at desc) t);
end $$;

-- which sources (a partner, a QR code, Instagram) bring people, and how many actually come
create or replace function public.staff_source_report() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object('source', coalesce(source, '(none)'), 'leads', n, 'event_signups', s, 'attended', a) order by n desc), '[]'::jsonb)
          from (select source, count(*)::int n, count(*) filter (where kind = 'event_signup')::int s, count(*) filter (where attended)::int a
                from public.leads where status <> 'spam' group by source) t);
end $$;

-- ── who may call what ─────────────────────────────────────────────────────
do $$
declare f record;
  everyone text[] := array['submit_form', 'event_signup', 'public_events', 'public_journal', 'public_post', 'public_teachers', 'unsubscribe'];
  signed_in text[] := array['my_role', 'teacher_save_profile', 'post_save', 'post_submit', 'post_get', 'my_posts',
    'staff_review_post', 'staff_add_teacher', 'staff_teachers', 'staff_remove_teacher', 'staff_save_event', 'staff_events', 'staff_delete_event',
    'staff_inbox', 'staff_inbox_counts', 'staff_lead_set', 'staff_mark_attended', 'staff_event_signups',
    'staff_social_save', 'staff_social_list', 'staff_social_delete', 'staff_audience', 'staff_source_report', 'is_teacher'];
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and (p.proname = any (everyone) or p.proname = any (signed_in)
                 or p.proname in ('_slugify', '_require_writer', '_looks_like_contact')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname = any (everyone) then execute format('grant execute on function %s to anon, authenticated', f.sig);
    elsif f.proname = any (signed_in) then execute format('grant execute on function %s to authenticated', f.sig); end if;
  end loop;
end $$;
