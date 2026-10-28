# Gilbert Flex home base: what we're building

One place that does the job of a Linktree, a calendar, sign-ups, event requests and a community journal, with the members club inside it. It started life as a radio station, and that spirit (a studio with its own voice) stays.

## Done
- Members club app (check-in, streaks, badges, perks, wall, staff tools) on Supabase, tested on Postgres 17.
- Links page: Instagram preview, today's classes, weekly schedule, events calendar, FAQ, Book a class (Teamup).
- "Book a class" button in the app.

## Next, in order
1. **Real forms.** Event request ("host with us"), partner request ("let's collab"), and a sign-up list. Saved in the database, emailed to the studio, shown in one inbox. This is also the start of the audience list. *(Space request: parked on purpose.)*
2. **Events from a list.** Staff add an event once; it appears on the calendar with its own sign-up page and QR code. After the event, mark who came.
3. **The journal (blog), written by teachers.**
   - Roles: owner, staff, teacher. A teacher can write and edit only their own posts.
   - Posts go in as drafts; an owner approves before they appear publicly (the brand stays safe).
   - Post types: *Teacher of the Week*, *Event of the Week*, and open posts. Each has a byline, photo and a link to their classes.
   - Photos via Supabase Storage.
4. **Instagram calendar.** Draft captions from the real schedule, owner approves, posts go out on a schedule through a connected tool (log in to Instagram yourself; no passwords in this repo).
5. **Audience lists + Mailchimp.** "Came to prenatal but not in 6 weeks", "came from the pastry partnership". Emails go through Mailchimp so unsubscribes and consent are handled.

## Later
- Studio Radio: the AI host reading the schedule, with calm studio music (needs approval before any music model is used).
- QR check-in; syncing with Teamup.

## Rules we keep
- Every write is safe to retry on a bad connection.
- Nobody sees anyone else's private data; teachers only touch their own posts.
- No real keys or passwords in git. Members and leads agree before we message them.
