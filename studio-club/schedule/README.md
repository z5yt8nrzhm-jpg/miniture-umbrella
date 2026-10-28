# Studio links and schedule page

`index.html` is the studio's link-in-bio page (also published as a Claude artifact): weekly class schedule, calendar of events, request forms, FAQ and links. It is a single static file with no tracking, cookies or network calls; the only links out are to Teamup (booking), Instagram, Google Maps and Google Fonts.

- **Booking platform: Teamup** (`goteamup.com/p/6251849-gilbert-flex-studio`). "Book a class" opens the Teamup schedule.
- **Update the schedule monthly** in the `WEEK` and `EVENTS` lists near the top of the `<script>`.
- **Live Teamup schedule (optional):** paste Teamup's embed code into the `#teamup-live` div (Teamup: Customer Experience > Customer Site > View Embed Instructions). The built-in schedule then hides itself.
- Host anywhere static (GitHub Pages, Netlify), or keep using the artifact link.

## Instagram preview at the top

Under the logo, the page shows Instagram's official profile preview for `@gilbertflexstudio`, then a Follow button. Instagram only shows it if the account is public. For a smoother live feed, make a free feed widget (Behold, LightWidget or SnapWidget): you log in to Instagram yourself on their site, they give you an embed code, and you paste it into the `#ig-live` div. The built-in preview then hides itself. No Instagram password or token is ever stored in this repo.
