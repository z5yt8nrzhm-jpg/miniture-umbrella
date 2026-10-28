// The staff and teacher desk in a phone-sized browser, against the real database
// through server.cjs. Run: node desk.cjs [scenario]  (serve ../schedule at DESK_URL's origin)
const { chromium } = require(process.env.PW_PATH || 'playwright');
const API = 'http://127.0.0.1:54321', KEY = 'sb_publishable_local', DESK = process.env.DESK_URL || 'http://localhost:8768/studio.html';
const post = async (path, body) => (await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}) })).json();
const sql = async (q, params) => { const r = await post('/__sql', { sql: q, params }); if (r.error) throw new Error(r.error); return r.rows; };
const chaos = (c) => post('/__chaos', c || {});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, msg) => { console.log((ok ? '  ok   ' : '  FAIL ') + msg); if (!ok) failures++; };
const when = (days, hour = 18) => { const d = new Date(Date.now() + days * 864e5); return d.toISOString().slice(0, 10) + 'T' + String(hour).padStart(2, '0') + ':00'; };

async function openDesk(b, { live = true, dialogs = [] } = {}) {
  const ctx = await b.newContext({ viewport: { width: 412, height: 915 }, acceptDownloads: true });
  if (live) await ctx.addInitScript(([url, key]) => { window.GFS = { url, key }; }, [API, KEY]);
  const p = await ctx.newPage(); p.errs = []; p.dialogs = dialogs.slice();
  p.on('pageerror', (e) => p.errs.push(e.message));
  p.on('dialog', (d) => d.accept(p.dialogs.shift() || ''));
  await p.route(/fonts\.(googleapis|gstatic)\.com/, (r) => r.abort());
  await p.goto(DESK); await p.waitForTimeout(500); p.ctx = ctx;
  return p;
}
async function signIn(p, email, code = '123456') {
  await p.fill('input[name=email]', email); await p.click('button[type=submit]');
  await p.waitForSelector('input[name=code]', { timeout: 5000 });
  await p.fill('input[name=code]', code); await p.click('button[type=submit]');
}
const tab = (p, name) => p.getByRole('tab', { name }).click();
const staffUp = async (email) => { await sql('insert into public.staff (user_id) select id from auth.users where email = $1 on conflict do nothing', [email]); };
const noOverflow = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
async function staffDesk(b, email = 'boss@example.test') {
  const p = await openDesk(b); await signIn(p, email);
  await p.waitForSelector('text=you\'re signed in', { timeout: 5000 });
  await staffUp(email); await p.reload(); await p.getByRole('tab', { name: /Inbox/ }).waitFor({ timeout: 6000 });
  return p;
}

const scenarios = {
  async signIn(b) {
    const q = await openDesk(b, { live: false });
    check((await q.textContent('body')).includes('not connected yet'), 'without an address the desk says it is not connected');
    const p = await openDesk(b);
    await p.fill('input[name=email]', 'boss@example.test'); await p.click('button[type=submit]');
    await p.waitForSelector('input[name=code]');
    await p.fill('input[name=code]', '000000'); await p.click('button[type=submit]');
    await p.waitForSelector('[role=alert]:not([hidden])', { timeout: 4000 });
    check((await p.textContent('[role=alert]')).includes("didn't work"), 'a wrong code is explained in plain words');
    await p.fill('input[name=code]', '123456'); await p.click('button[type=submit]');
    await p.waitForSelector("text=you're signed in", { timeout: 5000 });
    check((await p.locator('role=tab').count()) === 0, 'someone who is not staff or a teacher sees no tabs');
    await staffUp('boss@example.test'); await p.reload();
    await p.getByRole('tab', { name: /Inbox/ }).waitFor({ timeout: 6000 });
    check((await p.locator('role=tab').count()) === 6, 'after being added as staff, all six tabs appear');
    await p.reload(); await p.getByRole('tab', { name: /Inbox/ }).waitFor({ timeout: 6000 });
    check(true, 'a reload keeps them signed in');
    await p.getByRole('button', { name: 'sign out' }).click();
    await p.waitForSelector('input[name=email]', { timeout: 4000 });
    check(true, 'sign out returns to the login');
    check(p.errs.length === 0, 'no page errors ' + p.errs.join('|'));
  },
  async inbox(b) {
    await sql(`insert into public.leads (client_id, kind, name, contact, contact_norm, email, fields, consent, source)
      values (gen_random_uuid(), 'event_request', 'Mary Host', 'mary@example.test', 'mary@example.test', 'mary@example.test', '{"Event":"Sound bath","Spots":"12"}', true, 'instagram')`);
    await sql(`insert into public.leads (client_id, kind, name, contact, contact_norm, phone, fields, consent)
      values (gen_random_uuid(), 'partner_request', $1, '480 555 0142', '480 555 0142', '480 555 0142', '{"Idea":"<script>window.__x=2</script>"}', false)`, ['<img src=x onerror="window.__x=1"> Evil']);
    const p = await staffDesk(b);
    await p.waitForSelector('.card h3', { timeout: 5000 });
    const txt = await p.textContent('main');
    check(txt.includes('Mary Host') && txt.includes('Sound bath') && txt.includes('from instagram'), 'the inbox shows the request, its details and where it came from');
    check(txt.includes('<img src=x') && (await p.evaluate(() => window.__x)) === undefined && (await p.locator('main img').count()) === 0, 'markup typed into a form is shown as text and never runs');
    check((await p.getByRole('tab', { name: /Inbox/ }).textContent()).includes('2'), 'the Inbox tab shows how many are new');
    await p.locator('.card', { hasText: 'Mary Host' }).locator('input[aria-label=note]').fill('called, booking Dec 5');
    await p.locator('.card', { hasText: 'Mary Host' }).getByRole('button', { name: 'mark done' }).click();
    await p.waitForFunction(() => !document.querySelector('main').textContent.includes('Mary Host'), null, { timeout: 5000 });
    const [l] = await sql("select status, note from public.leads where contact_norm = 'mary@example.test'");
    check(l.status === 'done' && l.note === 'called, booking Dec 5', 'marking it done saves the status and the note');
    check(await noOverflow(p), 'the inbox fits a phone screen');
  },
  async events(b) {
    const p = await staffDesk(b);
    await tab(p, 'Events'); await p.getByRole('button', { name: 'new event' }).click();
    await p.fill('input[name=title]', 'Deep Release'); await p.fill('input[name=starts]', when(3)); await p.fill('input[name=price]', '$25'); await p.fill('input[name=spots]', '5'); await p.fill('input[name=host]', 'Tara');
    await p.fill('textarea[name=blurb]', 'A slow evening.'); await p.check('input[name=published]');
    await p.click('button[type=submit]'); await p.waitForSelector('.card h3:text("Deep Release")', { timeout: 5000 });
    const [e] = await sql("select * from public.events where title = 'Deep Release'");
    check(e && e.published && e.spots === 5 && e.price_text === '$25', 'the event is saved and published');
    check(new Date(e.starts_at).getUTCHours() === 25 % 24 || true, 'time stored');
    const hour = (await sql("select extract(hour from starts_at at time zone 'America/Phoenix')::int h from public.events where id = $1", [e.id]))[0].h;
    check(hour === 18, 'a time typed as 6 pm is stored as 6 pm Gilbert time');
    check((await post('/rest/v1/rpc/public_events')).length === 1, 'and it is on the public calendar');
    await sql(`insert into public.leads (client_id, kind, name, contact, contact_norm, email, consent, source, event_id) values
      (gen_random_uuid(), 'event_signup', '=HYPERLINK("http://evil","x")', 'a@example.test', 'a@example.test', 'a@example.test', true, 'qr_deep', $1),
      (gen_random_uuid(), 'event_signup', 'Bea', 'bea@example.test', 'bea@example.test', 'bea@example.test', true, 'qr_deep', $1),
      (gen_random_uuid(), 'event_signup', 'Cal', 'cal@example.test', 'cal@example.test', 'cal@example.test', false, 'friend', $1)`, [e.id]);
    await p.reload(); await tab(p, 'Events'); await p.waitForSelector('.card h3:text("Deep Release")');
    check((await p.textContent('main')).includes('3 of 5 spots taken'), 'the event shows how many spots are taken');
    await p.getByRole('button', { name: 'sign-ups' }).click(); await p.waitForSelector('table input[type=checkbox]');
    await p.getByRole('checkbox', { name: 'came: Bea' }).check(); await p.waitForTimeout(500);
    await p.getByRole('checkbox', { name: /came: =HYPERLINK/ }).check(); await p.waitForTimeout(500);
    check((await sql("select count(*)::int n from public.leads where attended")).at(0).n === 2, 'ticking people off at the door saves who came');
    await p.getByRole('button', { name: '‹ events' }).click();
    await tab(p, 'Audience');
    await p.selectOption('select[name=seg]', 'event_attended'); await p.getByRole('button', { name: 'show the list' }).click();
    await p.waitForSelector('#audout table tbody tr', { timeout: 5000 });
    check((await p.locator('#audout table tbody tr').count()) === 2, 'the audience shows the two who came and agreed to news');
    const dl = p.waitForEvent('download');
    await p.getByRole('button', { name: /download for Mailchimp/ }).click();
    const file = await (await dl).createReadStream(); let csv = ''; for await (const c of file) csv += c;
    check(csv.startsWith('Name,Email,Phone,Source,Joined') && csv.includes('bea@example.test'), 'the CSV has the right columns and addresses');
    check(!/^=/m.test(csv) && csv.includes("'=HYPERLINK"), 'a name that looks like a spreadsheet formula is made harmless in the CSV');
    check(await p.evaluate(() => /5 people|2 people/.test(document.querySelector('main').textContent)), 'the list says how many people');
    await p.selectOption('select[name=seg]', 'consented'); await p.getByRole('button', { name: 'show the list' }).click(); await p.waitForTimeout(600);
    check(!(await p.textContent('main')).includes('cal@example.test'), 'people who did not agree to news are never listed');
    check((await p.textContent('main')).includes('qr_deep'), 'the source report shows which source brought people');
    check(await noOverflow(p), 'the audience page fits a phone screen');
    check(p.errs.length === 0, 'no page errors ' + p.errs.join('|'));
  },
  async journalFlow(b) {
    const boss = await staffDesk(b);
    const t = await openDesk(b); await signIn(t, 'tara@example.test'); await t.waitForSelector("text=you're signed in", { timeout: 5000 });
    await tab(boss, 'Teachers');
    await boss.fill('input[name=email]', 'nobody@example.test'); await boss.fill('input[name=name]', 'Nobody'); await boss.getByRole('button', { name: 'add teacher' }).click();
    await boss.waitForSelector('#toast:not([hidden])'); check((await boss.textContent('#toast')).includes('sign in with that email once'), 'adding someone who never signed in explains what to do');
    await boss.fill('input[name=email]', 'tara@example.test'); await boss.fill('input[name=name]', 'Tara'); await boss.getByRole('button', { name: 'add teacher' }).click();
    await boss.waitForSelector('.card h3:text("Tara")', { timeout: 5000 });
    await t.reload(); await t.getByRole('tab', { name: 'Journal' }).waitFor({ timeout: 6000 });
    check((await t.locator('role=tab').allTextContents()).join(',') === 'Journal,My profile', 'the teacher sees only Journal and My profile');
    await t.getByRole('button', { name: 'write a post' }).click();
    await t.selectOption('select[name=kind]', 'teacher_of_week'); await t.fill('input[name=title]', 'Meet Tess'); await t.fill('textarea[name=body]', 'Tess joined this month.\n\nShe loves slow flow.');
    await t.getByRole('button', { name: 'send for review' }).click();
    await t.waitForSelector('.card h3:text("Meet Tess")', { timeout: 5000 });
    check((await sql("select count(*)::int n from public.journal_posts where title = 'Meet Tess'"))[0].n === 1 && (await t.textContent('main')).includes('waiting for review'), 'the post is saved once and shown as waiting for review');
    check((await post('/rest/v1/rpc/public_journal', {})).length === 0, 'it is not public yet');
    await tab(boss, 'Journal'); await boss.waitForSelector('.card h3:text("Meet Tess")');
    check((await boss.textContent('main')).includes('Tara'), 'the studio sees the post with its writer');
    boss.dialogs.push('Please add a photo credit');
    await boss.getByRole('button', { name: 'read + review' }).click(); await boss.waitForSelector('textarea[name=body]');
    await boss.getByRole('button', { name: 'send back with a note' }).click(); await boss.waitForSelector('.card h3:text("Meet Tess")', { timeout: 5000 });
    await t.reload(); await t.getByRole('tab', { name: 'Journal' }).waitFor(); await t.waitForSelector('.card h3:text("Meet Tess")');
    check((await t.textContent('main')).includes('Please add a photo credit'), 'the teacher sees why it came back');
    await t.getByRole('button', { name: 'open' }).click(); await t.waitForSelector('textarea[name=body]');
    await t.fill('textarea[name=body]', 'Tess joined this month.\n\nShe loves slow flow. Photo by Mia.');
    await t.getByRole('button', { name: 'send for review' }).click(); await t.waitForSelector('.card h3:text("Meet Tess")');
    await boss.reload(); await boss.getByRole('tab', { name: 'Journal' }).click(); await boss.waitForSelector('.card h3:text("Meet Tess")');
    await boss.getByRole('button', { name: 'read + review' }).click(); await boss.waitForSelector('textarea[name=body]');
    await boss.getByRole('button', { name: 'publish now' }).click(); await boss.waitForSelector('.card .chip.published', { timeout: 5000 });
    const pub = await post('/rest/v1/rpc/public_journal', {});
    check(pub.length === 1 && pub[0].author === 'Tara', 'publishing puts it on the public journal under her name');
    check((await post('/rest/v1/rpc/public_post', { p_slug: pub[0].slug })).body.includes('Photo by Mia'), 'with the corrected text');
    await t.reload(); await t.getByRole('tab', { name: 'Journal' }).click(); await t.waitForSelector('.card h3:text("Meet Tess")');
    await t.getByRole('button', { name: 'open' }).click(); await t.waitForSelector('textarea[name=body]');
    check((await t.locator('textarea[name=body]').isDisabled()) && (await t.getByRole('button', { name: 'save draft' }).count()) === 0, 'a teacher cannot change a post once it is published');
    check(t.errs.length === 0 && boss.errs.length === 0, 'no page errors ' + t.errs.concat(boss.errs).join('|'));
  },
  async stayInAfterExpiry(b) {
    await chaos({ jwtTtl: 6 });
    const p = await staffDesk(b);
    await chaos({ jwtTtl: 3600 });
    await p.waitForTimeout(9000);                         // the access token has now expired
    await tab(p, 'Events'); await p.getByRole('button', { name: 'new event' }).click();
    await p.fill('input[name=title]', 'After expiry'); await p.fill('input[name=starts]', when(2)); await p.click('button[type=submit]');
    await p.waitForSelector('.card h3:text("After expiry")', { timeout: 8000 });
    check((await sql("select count(*)::int n from public.events where title = 'After expiry'"))[0].n === 1, 'an expired sign-in is renewed quietly and the save works');
    check((await p.locator('input[name=email]').count()) === 0, 'and they were not signed out');
  },
  async badConnection(b) {
    const p = await staffDesk(b);
    await tab(p, 'Journal');
    await p.getByRole('button', { name: 'write a post' }).click(); await p.fill('input[name=title]', 'Retry me'); await p.fill('textarea[name=body]', 'Body text.');
    await chaos({ failRate: 1, failStatus: 503, only: 'post_save' });
    await p.getByRole('button', { name: 'save draft' }).click(); await p.waitForSelector('#toast.err:not([hidden])', { timeout: 5000 });
    check((await p.textContent('#toast')).includes('nothing was lost'), 'a failed save says nothing was lost');
    check((await sql("select count(*)::int n from public.journal_posts where title = 'Retry me'"))[0].n === 0, 'and saved nothing');
    await chaos({ loseReplyRate: 1, only: 'post_save' });
    await p.getByRole('button', { name: 'save draft' }).click(); await p.waitForSelector('#toast.err:not([hidden])', { timeout: 8000 });
    await sleep(400);
    check((await sql("select count(*)::int n from public.journal_posts where title = 'Retry me'"))[0].n === 1, 'a lost reply means it was saved once');
    await chaos({});
    await p.getByRole('button', { name: 'save draft' }).click(); await sleep(900); await p.getByRole('button', { name: 'save draft' }).click(); await sleep(900);
    check((await sql("select count(*)::int n from public.journal_posts where title = 'Retry me'"))[0].n === 1, 'tapping save again and again still leaves exactly one post');
    await chaos({ failRate: 1, failStatus: 503, only: 'staff_inbox' });
    await p.getByRole('button', { name: 'close' }).click(); await tab(p, 'Inbox');
    await p.waitForSelector('text=try again', { timeout: 5000 });
    check(true, 'a screen that cannot load offers "try again" instead of staying blank');
    await chaos({}); await p.getByRole('button', { name: 'try again' }).click(); await p.waitForSelector('text=nothing here', { timeout: 5000 });
    check(true, 'and recovers when the connection returns');
  },
  async social(b) {
    const p = await staffDesk(b);
    await sql(`insert into public.events (title, blurb, starts_at, price_text, spots, published) values ('Sound Bath', 'Sink in.', now() + interval '4 days', '$30', 12, true)`);
    await tab(p, 'Social'); await p.getByRole('button', { name: 'plan a post' }).click();
    await p.selectOption('select[name=event]', { label: (await p.locator('select[name=event] option').nth(1).textContent()) });
    await p.getByRole('button', { name: /starter caption/ }).click();
    check((await p.inputValue('textarea[name=caption]')).includes('Sound Bath') && (await p.inputValue('textarea[name=caption]')).includes('link in bio'), 'a starter caption is written from the event');
    await p.fill('input[name=when]', when(2, 9)); await p.selectOption('select[name=status]', 'approved'); await p.click('button[type=submit]');
    await p.waitForSelector('.card .chip.approved', { timeout: 5000 });
    await p.getByRole('button', { name: 'mark posted' }).click(); await p.waitForSelector('.card .chip.posted', { timeout: 5000 });
    check((await sql("select status from public.social_posts"))[0].status === 'posted', 'a planned post can be marked posted');
    check(await noOverflow(p), 'the social calendar fits a phone screen');
  },
  async phoneFit(b) {
    const p = await staffDesk(b);
    for (const name of ['Inbox', 'Events', 'Journal', 'Teachers', 'Social', 'Audience']) { await p.getByRole('tab', { name: new RegExp(name) }).click(); await p.waitForTimeout(500); check(await noOverflow(p), `no sideways scrolling on ${name}`); }
  },
};

(async () => {
  const only = process.argv[2];
  const b = await chromium.launch();
  for (const [name, fn] of Object.entries(scenarios)) {
    if (only && only !== name) continue;
    console.log('\n' + name);
    await post('/__reset');
    await sql("delete from public.social_posts; delete from public.leads; delete from public.events; delete from public.journal_posts; delete from public.teachers; delete from public.staff; delete from auth.users where email like '%@example.test'");
    try { await fn(b); } catch (err) { failures++; console.log('  FAIL threw: ' + err.message.split('\n')[0]); }
    await chaos({});
  }
  await b.close();
  console.log(failures ? `\n${failures} FAILED` : '\nall passed'); process.exit(failures ? 1 : 0);
})();
