# Gilbert Flex Studio links site

Static site served by the Cloudflare Worker `gilbert-flex-studio`
(https://gilbert-flex-studio.z5yt8nrzhm.workers.dev).

- **Change links:** edit `public/config.js`
- **Change the weekly schedule or events:** edit `public/schedule.js`

Cloudflare rebuilds and redeploys the site automatically on every push to this branch
(build command: none, deploy command: `npx wrangler deploy`).

## Also in this repo

- `studio-club/` — Gilbert Flex Club members app (Flutter + Supabase), its tests, and the studio links/schedule pages
- `reel/` — studio promo reels: the mat pilates flyer reel and `reel/calendar/` (October flips to November)

Only `public/` is published to the website. The other folders don't affect it.
