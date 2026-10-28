# Gilbert Flex Club

The members club for Gilbert Flex Studio: class check-ins, streaks and badges, a member card with perks, and a friendly community wall. A Flutter app (Android, iOS, web) on a Supabase backend.

Without keys the app runs in **demo mode** with sample data on the device, so you can look around before any setup.

## Put it live (about 20 minutes)

1. **Create a Supabase project** at supabase.com (the free plan is fine to start).
2. **Create the tables and rules.** In the SQL editor, run each file in `supabase/migrations/` in order. (Or `supabase db push` with the CLI.) Do **not** run `seed.sql`; it is demo classes for testing only.
3. **Sign-in emails.** Members sign in with a 6-digit code emailed to them, with no password.
   - Auth → Emails → SMTP: add a real email provider (Resend, Postmark, SES...). Supabase's built-in sender only delivers to your own team's addresses, so without this members will never receive a code.
   - Auth → Email Templates → *Magic Link*: paste `supabase/templates/otp.html`. It shows `{{ .Token }}`, the code.
4. **Make yourself staff.** Sign in once in the app, then in the SQL editor:
   ```sql
   insert into public.staff (user_id) select id from auth.users where email = 'you@example.com';
   ```
   A STAFF tab appears: create classes (each gets a check-in code to show at the desk), look up a member by number, mark perks as used, and review reported wall posts.
5. **Build the app with your project's URL and publishable key** (Project settings → API; use the publishable/anon key, never the secret key):
   ```sh
   flutter build apk --release \
     --dart-define=SUPABASE_URL=https://YOURREF.supabase.co \
     --dart-define=SUPABASE_KEY=sb_publishable_...
   ```
   Use `flutter build web ...` for the web version.
6. **Edit the placeholders** in `supabase/migrations/20261028000300_club_reference_data.sql`: the three perks (free class at 25, guest pass at 50, gift at 100) are examples, so set what the studio will really honour.

## The links page and the studio desk (`schedule/`)

Two plain web pages that talk to the same Supabase project. Host them anywhere that serves static files (GitHub Pages, Netlify, your website).

| Page | Who uses it | What it does |
|---|---|---|
| `schedule/index.html` | everyone | Instagram preview, today's classes, weekly schedule, events calendar with sign-up pages, request forms (host an event, partner), join-our-list, the journal and teachers, unsubscribe link |
| `schedule/studio.html` | you, your mom, teachers | Sign in with an emailed code. **Team:** inbox of every form, events and who came, journal review and publish, teachers, social calendar, audience lists and CSV for Mailchimp. **Teachers:** write posts (sent to the team for approval) and edit their profile |

**To go live**, open each file and set the two values at the top (`window.GFS = {url, key}`): the project URL and the **publishable** key. Leave them empty and the links page still works on its own (forms build a message to copy, events come from the lists in the file); the desk says it isn't connected.

**Making the first team member:** open `studio.html`, sign in with your email, then run in the Supabase SQL editor:
```sql
insert into public.staff (user_id) select id from auth.users where email = 'you@example.com';
```
Everyone after that is added in the app: a teacher opens `studio.html` and signs in once, then a team member adds them under **Teachers** with their email.

**Tracking what works:** add `?src=name` to any link you share (a partner, a flyer, an Instagram story) and every sign-up from it is tagged. The Audience tab shows which sources bring people and how many actually came. Event pages have a "copy sign-up link" button that tags it for you; put that link in a QR code.

**Rules built in:** a form needs a phone or email; 5 per contact per hour and 300 per hour overall; a hidden field catches simple bots; people are only added to the audience if they tick "ok to send news"; the unsubscribe link removes them from every list; teachers can only touch their own posts and nothing goes public until the team approves it.

**Email alerts when a form arrives** (`supabase/functions/notify/`): deploy the function, add two Database Webhooks (table `leads` on INSERT; table `journal_posts` on UPDATE) that call it with a `x-webhook-secret` header, and set its secrets (`WEBHOOK_SECRET`, `RESEND_API_KEY`, `NOTIFY_TO`, `NOTIFY_FROM`, `DESK_URL`; the file header explains each). Without it everything still works; you just check the inbox yourself (the tab shows a count and refreshes every 30 seconds).

**Journal photos:** the migration creates a public `journal` bucket where each writer can only upload into their own folder. The desk takes a photo *link* for now (an uploader button is the next step).

## How it works for members

- **Check in**: type the 6-character code the studio shows for that class. Allowed from 45 minutes before class to 30 minutes after it ends, twice a day. Wrong codes are rate-limited (8 per 15 minutes).
- **Streaks** count consecutive weeks (Studio time, America/Phoenix) with at least one class; a streak stays alive through the following week. Badges at 1/10/25/50/100 classes and 4/8/12-week streaks.
- **Wall**: 500 characters, 5 posts an hour. Three different members reporting a post hides it automatically and staff review it.
- Members can delete their account in the app (Me → Delete my account); everything of theirs is removed.

## Built for flaky phone signal

- Every write is safe to repeat: a check-in counts once per member per class; a wall post carries an ID made on the phone, so retries never double-post; cheers set on/off instead of toggling.
- Posts written offline are kept on the phone (even after closing the app) and sent when the connection returns, retrying after 4, 8, 16 seconds, then every 30.
- The app opens from its last saved data, shows a banner when offline, only signs a member out when the sign-in is truly rejected (not on a bad signal), and turns captive-portal and server error pages into plain-language messages.

## What was tested

```sh
supabase/tests/run.sh        # needs a local Postgres: privacy, flows, concurrency, volume
supabase/tests/dump_contract.sh   # regenerates test/contract/rpc_contract.json
flutter analyze && flutter test   # 73 tests
node --experimental-strip-types supabase/functions/notify/email.test.ts
cd e2e && npm install && ./setup.sh && node server.cjs &   # then serve a web build, then: node e2e.cjs
#   (cd schedule && python3 -m http.server 8768 &)   then: node site.cjs && node desk.cjs
```

- **Database**: members cannot read each other's data, codes, member numbers or reports; functions cannot be called by signed-out users; double-taps and parallel check-ins (pgbench) never double count; behaviour verified with tens of thousands of rows; the checks were proven by removing rules and watching them fail.
- **App contract**: a test fails if the app calls a database function (or argument) that does not exist, so app and database cannot drift apart.
- **Browser, phone-size, real Postgres** (`e2e/`): sign-up, check-in, posting, lost replies after the server saved the data, 50% request failures, a total outage with the app reopened, offline posting, access-token expiry, account deletion. The same suite ran green three times in a row.
- **Links page and desk, real browser at phone size, real Postgres**: forms retried and lost-reply safe, bot trap, event spots (10 of 400 people in a race), the journal's write, review, send-back and publish flow, expired sign-ins renewed quietly, injection attempts shown as text, CSV formulas neutralised, nothing scrolls sideways.
- **Screen readers**: a widget test checks wall posts are readable and cheerable. (It caught a real bug: post text was exposed as an editable field.)

## Not verified, and not built yet

- Not run against a hosted Supabase project (the sandbox this was built in cannot reach one). `e2e/server.cjs` stands in for Supabase's sign-in and REST layers in front of the real database, so the first real sign-in is the one thing left to confirm. The local database ran Postgres 16; CI uses 17, which Supabase runs.
- Not tried on a physical phone or with a real email provider; Android build and the browser were the targets.
- Check-in is by typing the code; **QR scanning is not built**.
- **Instagram:** the page shows Instagram's public preview and the desk plans posts, but nothing posts for you yet (that needs Meta's business login, done by you in their site). The live feed inside the Flutter app is not built.
- **Journal photo upload** (a button) and **live-updating inbox** (Realtime is enabled on the table; the desk polls instead) are not built. The email-alert function's wrapper is untested here (no Deno or Resend account); its email-building logic is tested.
- **Mailchimp** is by CSV export for now, not a live connection.
- The booking platform is **Teamup**. The app's Book a class button and the page link to it, but the club does **not** sync with it: classes are created by staff in the app, so schedules are entered twice for now.
- Perks are placeholders (see step 6).
