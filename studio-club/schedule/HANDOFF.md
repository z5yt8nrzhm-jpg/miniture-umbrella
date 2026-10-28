# Handoff note: Gilbert Flex home base

For the person building or restyling the website. Everything here is plain HTML, CSS and JavaScript. No build step, no framework, no cookies, no trackers.

## What each piece is

| File | What it is | Safe to restyle? |
|---|---|---|
| `schedule/index.html` | The public links page: Instagram preview, schedule, calendar, forms, journal. One self-contained file. | Yes. Keep the element `id`s (the script looks them up) and the `rpc("...")` calls. |
| `schedule/studio.html` | The private studio desk for the team and teachers (sign-in by emailed code). | Leave to us, or restyle only the CSS. It is not linked from the public page. |
| `supabase/` | The database, its safety rules and tests. | Do not edit by hand. Changes go in new migration files. |
| `lib/` and the rest | The members club phone app (Flutter). | Separate project; link to it once it is published. |

## Two values to set (top of both pages)
```html
<script id="gfs-config">window.GFS={url:"https://YOURREF.supabase.co",key:"sb_publishable_..."};</script>
```
Use the **publishable** key. It is meant to be public: what it can do is limited by the database rules, not by secrecy. Never put the secret or service key in a web page.

## Things to change as the studio changes
- **Weekly classes and upcoming events** (until events are entered in the studio desk): the `WEEK` and `EVENTS` lists near the top of the script in `index.html`.
- **Teamup link:** search `goteamup.com`.
- **Instagram handle:** search `gilbertflexstudio`. A free live-feed widget can replace the built-in preview: paste its embed code into the `#ig-live` div.
- **Phone number and DM link** in the request forms.

## Hosting
Any static host. Put `index.html` at the public address (for example `gilbertflex.com/links`) and `studio.html` somewhere unlisted (it also has `noindex`). Both pages must be served over **https**.

## Please keep
- Text from forms and posts is always inserted as plain text (never as HTML). Keep it that way if you restyle.
- The hidden `website` field in each form (a trap for bots) and the consent checkbox.
- The `?src=` tracking: links with `?src=something` tag every sign-up.

## How it was checked
Browser tests run both pages at phone size against a real database: `studio-club/e2e/site.cjs` and `desk.cjs` (see the README). If you change the page and want to be sure nothing broke: `node site.cjs`.
