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
cd e2e && npm install && ./setup.sh && node server.cjs &   # then serve a web build, then: node e2e.cjs
```

- **Database**: members cannot read each other's data, codes, member numbers or reports; functions cannot be called by signed-out users; double-taps and parallel check-ins (pgbench) never double count; behaviour verified with tens of thousands of rows; the checks were proven by removing rules and watching them fail.
- **App contract**: a test fails if the app calls a database function (or argument) that does not exist, so app and database cannot drift apart.
- **Browser, phone-size, real Postgres** (`e2e/`): sign-up, check-in, posting, lost replies after the server saved the data, 50% request failures, a total outage with the app reopened, offline posting, access-token expiry, account deletion. The same suite ran green three times in a row.
- **Screen readers**: a widget test checks wall posts are readable and cheerable. (It caught a real bug: post text was exposed as an editable field.)

## Not verified, and not built yet

- Not run against a hosted Supabase project (the sandbox this was built in cannot reach one). `e2e/server.cjs` stands in for Supabase's sign-in and REST layers in front of the real database, so the first real sign-in is the one thing left to confirm. The local database ran Postgres 16; CI uses 17, which Supabase runs.
- Not tried on a physical phone or with a real email provider; Android build and the browser were the targets.
- Check-in is by typing the code; **QR scanning is not built**.
- The booking platform (Momence, Arketa or Glofox) is **not connected**; classes are created by staff in the app, so schedules are entered twice for now.
- Perks are placeholders (see step 6).
