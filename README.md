# Gilbert Flex Studio links site

Static site served by the Cloudflare Worker `dry-rain-c1d4`
(https://dry-rain-c1d4.z5yt8nrzhm.workers.dev).

- **Change links:** edit `public/config.js`
- **Change the weekly schedule or events:** edit `public/schedule.js`

Cloudflare rebuilds and redeploys the site automatically on every push to this branch
(build command: none, deploy command: `npx wrangler deploy`).
