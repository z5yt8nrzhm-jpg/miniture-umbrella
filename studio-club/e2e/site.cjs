// The public links page in a phone-sized browser, talking to the real database
// through server.cjs. Run: node site.cjs [scenario]   (needs the page served at SITE_URL)
const { chromium } = require(process.env.PW_PATH || 'playwright');
const API = 'http://127.0.0.1:54321', KEY = 'sb_publishable_local', SITE = process.env.SITE_URL || 'http://localhost:8768/index.html';
const post = async (path, body) => (await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}) })).json();
const sql = async (q, params) => { const r = await post('/__sql', { sql: q, params }); if (r.error) throw new Error(r.error); return r.rows; };
const chaos = (c) => post('/__chaos', c || {});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, msg) => { console.log((ok ? '  ok   ' : '  FAIL ') + msg); if (!ok) failures++; };
const leads = async (where = 'true', params = []) => (await sql(`select * from public.leads where ${where} order by created_at`, params));

async function open(b, { live = true, hash = '', src = 'qr_test', offline = false } = {}) {
  const ctx = await b.newContext({ viewport: { width: 412, height: 915 } });
  if (live) await ctx.addInitScript(([url, key]) => { window.GFS = { url, key }; }, [API, KEY]);
  const p = await ctx.newPage();
  p.errs = []; p.on('pageerror', (e) => p.errs.push(e.message));
  await p.route(/fonts\.(googleapis|gstatic)\.com|instagram\.com/, (r) => r.abort());
  await p.goto(`${SITE}${src ? '?src=' + src : ''}${hash}`);
  await p.waitForTimeout(600);
  p.ctx = ctx;
  return p;
}
const noOverflow = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);

const scenarios = {
  async offlineFallback(b) {
    const p = await open(b, { live: false, hash: '#host' });
    check((await p.locator('a[data-live]').first().isHidden()) === true, 'without an address, the journal and join links are hidden');
    await p.fill('#h1', 'Moon bath'); await p.fill('#h8', 'me@example.test'); await p.click('#hostform button[type=submit]');
    await p.waitForSelector('#hostout pre', { timeout: 4000 });
    check((await p.textContent('#hostout pre')).includes('Moon bath'), 'the form still builds a message to send');
    check((await p.textContent('#hostout pre')).includes('Contact: me@example.test') && !(await p.textContent('#hostout pre')).includes('website'), 'and leaves out the hidden trap field');
    check((await leads()).length === 0, 'nothing reached the database');
  },
  async hostForm(b) {
    const p = await open(b, { hash: '#host' });
    await p.fill('#h1', 'Full Moon Sound Bath'); await p.fill('#h2', 'Sat 6pm'); await p.fill('#h4', 'Mary, @marysounds'); await p.fill('#h6', '15'); await p.fill('#h8', 'mary@example.test');
    await p.check('#hostform input[name=consent]');
    await p.click('#hostform button[type=submit]');
    await p.waitForSelector('#hostout:not([hidden])', { timeout: 5000 });
    const [l] = await leads("contact_norm = 'mary@example.test'");
    check(!!l && l.kind === 'event_request', 'the request is saved as an event request');
    check(l && l.name === 'Mary, @marysounds' && l.fields.Event === 'Full Moon Sound Bath' && l.fields.Spots === '15', 'with the details the host typed');
    check(l && l.consent === true && l.source === 'qr_test', 'consent and the QR source were kept');
    check(p.errs.length === 0, 'no page errors ' + p.errs.join('|'));
  },
  async missingContact(b) {
    const p = await open(b, { hash: '#partner' });
    await p.fill('#p1', 'Cafe Luna'); await p.click('#partform button[type=submit]');
    await p.waitForSelector('#parterr:not([hidden])', { timeout: 4000 });
    check((await p.textContent('#parterr')).includes('phone or email'), 'a form without a contact asks for one, in plain words');
    check((await leads()).length === 0, 'and saves nothing');
    await p.fill('#p5', '480 555 0142'); await p.click('#partform button[type=submit]');
    await p.waitForSelector('#partout:not([hidden])', { timeout: 4000 });
    check((await leads("phone = '480 555 0142'")).length === 1, 'a phone number works as contact');
  },
  async retriesAndLostReplies(b) {
    const p = await open(b, { hash: '#host' });
    await p.fill('#h4', 'Pat'); await p.fill('#h8', 'pat@example.test');
    await chaos({ failRate: 1, failStatus: 503, only: 'submit_form' });
    await p.click('#hostform button[type=submit]');
    await p.waitForSelector('#hosterr:not([hidden])', { timeout: 5000 });
    check((await p.textContent('#hosterr')).includes('nothing was lost'), 'a failed send says nothing was lost');
    check((await leads("contact_norm = 'pat@example.test'")).length === 0, 'and nothing was saved');
    await chaos({ loseReplyRate: 1, only: 'submit_form' });                // saved, but the phone never hears back
    await p.click('#hostform button[type=submit]');
    await p.waitForSelector('#hosterr:not([hidden])', { timeout: 8000 });
    await sleep(500);
    check((await leads("contact_norm = 'pat@example.test'")).length === 1, 'a lost reply means it WAS saved once');
    await chaos({});
    await p.click('#hostform button[type=submit]');
    await p.waitForSelector('#hostout:not([hidden])', { timeout: 5000 });
    check((await leads("contact_norm = 'pat@example.test'")).length === 1, 'tapping again after that still leaves exactly one');
  },
  async botTrap(b) {
    const p = await open(b, { hash: '#join' });
    await p.fill('#j1', 'Robot'); await p.fill('#j2', 'robot@example.test');
    await p.evaluate(() => { document.querySelector('#joinform [name=website]').value = 'http://spam.test'; });
    await p.click('#joinform button[type=submit]');
    await p.waitForSelector('#joinout:not([hidden])', { timeout: 4000 });
    check((await p.textContent('#joinout')).includes('on the list'), 'a bot is told it worked');
    check((await leads("contact_norm = 'robot@example.test'")).length === 0, 'but nothing was stored');
  },
  async joinList(b) {
    const p = await open(b, { hash: '#join' });
    await p.fill('#j1', 'Jo'); await p.fill('#j2', 'jo@example.test'); await p.click('#joinform button[type=submit]');
    await p.waitForSelector('#joinout:not([hidden])', { timeout: 4000 });
    const [l] = await leads("contact_norm = 'jo@example.test'");
    check(l && l.kind === 'signup' && l.consent === true, 'joining the list is saved with consent (the box starts ticked)');
  },
  async events(b) {
    const ev = (await sql(`insert into public.events (title, blurb, starts_at, ends_at, price_text, spots, host_name, published)
      values ('Deep Release', E'A slow evening.\\n\\nBring a blanket.', now() + interval '2 days', now() + interval '2 days 2 hours', '$25', 1, 'Tara', true) returning id`))[0].id;
    await sql(`insert into public.events (title, starts_at, published) values ('Hidden plan', now() + interval '3 days', false)`);
    const p = await open(b, { hash: '#calendar' });
    await p.waitForSelector('#evlist .cls.ev', { timeout: 5000 });
    const list = await p.textContent('#evlist');
    check(list.includes('Deep Release') && list.includes('1 spot left'), 'the calendar lists the event with spots left');
    check(!list.includes('Hidden plan') && !list.includes('Sound Bath Sunday'), 'unpublished events are not shown, and the built-in list is replaced');
    check(await noOverflow(p), 'the calendar fits a phone screen');
    await p.click('#evlist a[href^="#event="]');
    await p.waitForSelector('#evform', { timeout: 4000 });
    check((await p.textContent('#eventbody')).includes('Bring a blanket.'), 'the event page shows the details');
    await p.fill('#ev1', 'Ann'); await p.fill('#ev2', 'ann@example.test'); await p.check('#evform input[name=consent]');
    await p.click('#evform button[type=submit]');
    await p.waitForSelector('#evout:not([hidden])', { timeout: 5000 });
    check((await leads('event_id = $1', [ev])).length === 1, 'signing up saves one spot');
    const q = await open(b, { hash: `#event=${ev}` });
    await q.waitForSelector('#eventbody', { timeout: 4000 }); await q.waitForTimeout(800);
    check((await q.textContent('#eventbody')).includes('this one is full'), 'the next visitor sees the event is full');
    check((await q.locator('#evform').count()) === 0, 'and gets no sign-up form');
    const r = await open(b, { hash: '#event=00000000-0000-4000-8000-000000000000' });
    await r.waitForTimeout(1000);
    check((await r.textContent('#eventbody')).includes("isn't open any more"), 'an old or wrong event link says so kindly');
  },
  async journal(b) {
    const u = (await sql(`insert into auth.users (email) values ('writer@example.test') returning id`))[0].id;
    await sql(`insert into public.teachers (user_id, display_name, bio) values ($1, 'Tara', 'Teaches slow flow.')`, [u]);
    await sql(`insert into public.journal_posts (author_id, author_name, client_id, kind, title, body, slug, status, published_at)
      values ($1, 'Tara', gen_random_uuid(), 'teacher_of_week', 'Meet <img src=x onerror="window.__xss=1"> Tess', E'Line one.\\n\\nSecond <script>window.__xss=2</script> paragraph.', 'meet-tess-abc123', 'published', now())`, [u]);
    await sql(`insert into public.journal_posts (author_id, author_name, client_id, title, body, status) values ($1, 'Tara', gen_random_uuid(), 'Secret draft', 'x', 'draft')`, [u]);
    const p = await open(b, { hash: '#journal' });
    await p.waitForSelector('#journallist .card', { timeout: 5000 });
    const txt = await p.textContent('#journallist');
    check(txt.includes('teacher of the week') && txt.includes('by Tara'), 'the journal lists the published post with its writer');
    check(!txt.includes('Secret draft'), 'drafts never appear');
    check((await p.textContent('#teacherlist')).includes('Teaches slow flow.'), 'teachers are shown');
    check(await noOverflow(p), 'the journal fits a phone screen');
    await p.click('#journallist .card'); await p.waitForSelector('#postbody h1', { timeout: 4000 });
    check((await p.locator('#postbody p').count()) >= 3, 'the post is shown as separate paragraphs');
    check((await p.textContent('#postbody h1')).includes('<img src=x'), 'markup in a title is shown as plain text');
    check((await p.evaluate(() => window.__xss)) === undefined, 'and nothing in a post can run code');
    check((await p.locator('#postbody img, #postbody script').count()) === 0, 'no injected elements');
    const q = await open(b, { hash: '#post=secret-draft' });
    await q.waitForTimeout(900);
    check((await q.textContent('#postbody')).includes("couldn't find"), 'a post that is not published cannot be opened by guessing its address');
  },
  async unsubscribe(b) {
    const p0 = await open(b, { hash: '#join' });
    await p0.fill('#j1', 'Una'); await p0.fill('#j2', 'una@example.test'); await p0.click('#joinform button[type=submit]');
    await p0.waitForSelector('#joinout:not([hidden])');
    const [l] = await leads("contact_norm = 'una@example.test'");
    const p = await open(b, { hash: `#unsubscribe=${l.unsub_token}` });
    await p.waitForFunction(() => /unsubscribed/.test(document.getElementById('unsubmsg').textContent), null, { timeout: 5000 });
    check((await leads("contact_norm = 'una@example.test' and unsubscribed_at is not null")).length === 1, 'the link unsubscribes them in the database');
    const q = await open(b, { hash: '#unsubscribe=not-a-token' });
    await q.waitForTimeout(500);
    check((await q.textContent('#unsubmsg')).includes("doesn't look right"), 'a broken link explains what to do');
  },
  async phoneFit(b) {
    for (const h of ['', '#schedule', '#calendar', '#host', '#partner', '#join', '#journal']) {
      const p = await open(b, { hash: h });
      check(await noOverflow(p), `no sideways scrolling on ${h || '#home'}`);
      await p.ctx.close();
    }
  },
};

(async () => {
  const only = process.argv[2];
  const b = await chromium.launch();
  for (const [name, fn] of Object.entries(scenarios)) {
    if (only && only !== name) continue;
    console.log('\n' + name);
    await post('/__reset');
    await sql("delete from public.leads; delete from public.events; delete from public.journal_posts; delete from public.teachers; delete from auth.users where email like '%@example.test'");
    try { await fn(b); } catch (err) { failures++; console.log('  FAIL threw: ' + err.message.split('\n')[0]); }
    await chaos({});
  }
  await b.close();
  console.log(failures ? `\n${failures} FAILED` : '\nall passed'); process.exit(failures ? 1 : 0);
})();
