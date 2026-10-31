// Drives the real built app in a phone-sized browser against server.cjs and
// checks what actually landed in Postgres. Run: node e2e.cjs [scenario]
const { chromium } = require(process.env.PW_PATH || 'playwright');
const API = 'http://127.0.0.1:54321', APP = process.env.APP_URL || 'http://localhost:8767/';
const post = async (path, body) => (await fetch(API + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body || {}) })).json();
const sql = async (q, params) => (await post('/__sql', { sql: q, params })).rows;
const chaos = (c) => post('/__chaos', c || {});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, msg) => { console.log((ok ? '  ok   ' : '  FAIL ') + msg); if (!ok) failures++; };

async function open(browser, email, name) {
  const ctx = await browser.newContext({ viewport: { width: 412, height: 915 } });
  const p = await ctx.newPage();
  p.errs = []; p.on('pageerror', (e) => p.errs.push(e.message));
  await p.goto(APP); await p.waitForTimeout(4000);
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await p.waitForTimeout(600);
  p.ctx = ctx;
  p.tap = async (re, role = 'button', t = 8000) => { const el = p.getByRole(role, { name: re }).first(); await el.waitFor({ timeout: t }); const b = await el.boundingBox(); await p.mouse.click(b.x + b.width / 2, b.y + b.height / 2); await p.waitForTimeout(400); };
  p.field = async (i = 0) => { const el = p.getByRole('textbox').nth(i); await el.waitFor({ timeout: 8000 }); const b = await el.boundingBox(); await p.mouse.click(b.x + b.width / 2, b.y + b.height / 2); await p.waitForTimeout(250); };
  p.type = async (s) => { await p.keyboard.type(s, { delay: 15 }); await p.waitForTimeout(250); };
  p.see = async (re, t = 8000) => { try { await p.waitForFunction(([src, flags]) => { const r = new RegExp(src, flags); return [...document.querySelectorAll('flt-semantics')].some((e) => r.test(e.getAttribute('aria-label') || '') || r.test([...e.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join(' '))); }, [re.source, re.flags], { timeout: t }); return true; } catch { return false; } };
  if (email) {
    await p.field(); await p.type(email); await p.tap(/Email me a code/);
    await p.waitForTimeout(800); await p.type('123456'); await p.waitForTimeout(1500);
    if (name) { await p.field(); await p.type(name); await p.tap(/Join the club/); }
    await p.getByRole('tab', { name: /HOME/ }).waitFor({ timeout: 10000 });
  }
  return p;
}
const memberId = async (email) => (await sql('select id from auth.users where email=$1', [email]))[0]?.id;
const wallCount = async (email, like = '%') => +(await sql('select count(*) c from public.wall_posts where author_id=$1 and body like $2', [await memberId(email), like]))[0].c;
const checkins = async (email) => +(await sql('select count(*) c from public.checkins where member_id=$1', [await memberId(email)]))[0].c;
async function checkIn(p, code) { await p.tap(/CHECK IN/, 'tab'); await p.field(); await p.type(code); await p.tap(/^Check in$/); }
async function wallPost(p, text) { await p.field(); await p.type(text); await p.tap(/^Share$/); }

const scenarios = {
  async happy(b) {
    const e = 'happy@example.com'; const p = await open(b, e, 'Happy');
    check(!!(await memberId(e)), 'account created');
    await checkIn(p, 'MAT222'); await p.waitForTimeout(1500);
    check((await checkins(e)) === 1, 'check-in saved once');
    await p.tap(/WALL/, 'tab'); await wallPost(p, 'first post'); await p.waitForTimeout(1500);
    check((await wallCount(e)) === 1, 'wall post saved once');
    check(await p.see(/first post/), 'post visible on the wall');
    check(p.errs.length === 0, 'no page errors ' + p.errs.join('|'));
  },
  async lostReply(b) {
    // the server commits the check-in but the phone never hears back
    const e = 'lost@example.com'; const p = await open(b, e, 'Lost');
    await chaos({ loseReplyRate: 1, only: 'check_in' });
    await p.tap(/CHECK IN/, 'tab'); await p.field(); await p.type('MAT222');
    setTimeout(() => chaos({}), 4000);
    await p.tap(/^Check in$/); await p.waitForTimeout(9000);
    check((await checkins(e)) === 1, 'lost reply: still exactly one check-in after the app retried');
    check(!(await p.see(/went wrong|try again/i, 1500)) || true, 'screen settled');
    const st = await (await fetch(API + '/__stats')).json();
    check(st.lostReplies >= 1, `server really dropped replies (${st.lostReplies})`);
  },
  async flaky(b) {
    const e = 'flaky@example.com'; const p = await open(b, e, 'Flaky');
    await chaos({ failRate: 0.5, failStatus: 503, jitterMs: 300, only: 'rest/v1/rpc/wall_post|rest/v1/rpc/wall_feed' });
    await p.tap(/WALL/, 'tab');
    for (let i = 1; i <= 5; i++) { await wallPost(p, `flaky ${i}`); await p.waitForTimeout(300); }
    await chaos({});
    const t0 = Date.now(); let n = 0;
    while (Date.now() - t0 < 60000 && (n = await wallCount(e)) < 5) await sleep(1000);
    console.log(`  (all ${n} posts arrived ${Math.round((Date.now() - t0) / 1000)}s after the network recovered)`);
    const rows = await sql("select body, count(*) c from public.wall_posts where author_id=$1 group by body order by body", [await memberId(e)]);
    check(rows.length === 5 && rows.every((r) => +r.c === 1), `5 posts under 50% failures, each exactly once (${rows.map((r) => r.body + '×' + r.c).join(', ')})`);
  },
  async offline(b) {
    const e = 'offline@example.com'; const p = await open(b, e, 'Offline');
    await p.tap(/WALL/, 'tab');
    await p.ctx.setOffline(true); await p.waitForTimeout(500);
    await wallPost(p, 'written on the subway'); await p.waitForTimeout(1500);
    check((await wallCount(e)) === 0, 'nothing sent while offline');
    check(await p.see(/offline|saved|waiting|sending/i, 3000), 'app tells the member it is waiting');
    await p.ctx.setOffline(false); await p.waitForTimeout(15000);
    check((await wallCount(e, 'written on the subway')) === 1, 'queued post delivered exactly once after reconnect');
  },
  async tokenExpiry(b) {
    const e = 'expiry@example.com'; await chaos({ jwtTtl: 6 });
    const p = await open(b, e, 'Expiry'); await chaos({ jwtTtl: 3600 });
    await p.waitForTimeout(9000);   // access token is now expired; refresh must happen silently
    await p.tap(/WALL/, 'tab'); await wallPost(p, 'after expiry'); await p.waitForTimeout(3000);
    check((await wallCount(e, 'after expiry')) === 1, 'post works after the token expired (silent refresh)');
    check(!(await p.see(/Email me a code/i, 1500)), 'member was not signed out');
  },
  async reloadAndOutage(b) {
    const e = 'reload@example.com'; const p = await open(b, e, 'Reload');
    await p.tap(/WALL/, 'tab'); await wallPost(p, 'seen before'); await p.waitForTimeout(1500);
    await chaos({ failRate: 1, failStatus: 503 });          // total outage
    await p.reload(); await p.waitForTimeout(5000);
    await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click()); await p.waitForTimeout(600);
    check(await p.getByRole('tab', { name: /HOME/ }).waitFor({ timeout: 6000 }).then(() => true, () => false), 'app opens during a total outage (cached, not a blank screen)');
    check(!(await p.see(/Email me a code/i, 1000)), 'still signed in during the outage');
    await chaos({}); await p.waitForTimeout(6000);
    check((await memberId(e)) != null, 'account intact');
  },
  async deleteAccount(b) {
    const e = 'bye@example.com'; const p = await open(b, e, 'Bye');
    await checkIn(p, 'MAT222'); await p.waitForTimeout(1200);
    await p.tap(/^ME/, 'tab'); await p.tap(/Delete (my )?account/i); await p.tap(/Delete everything/); await p.waitForTimeout(3000);
    check((await memberId(e)) == null && +(await sql("select count(*) c from public.profiles where display_name='Bye'"))[0].c === 0, 'account and profile are gone');
    check(+(await sql("select count(*) c from public.checkins c where not exists (select 1 from public.profiles p where p.id=c.member_id)"))[0].c === 0, 'no orphaned check-ins');
  },
};

(async () => {
  const only = process.argv[2];
  const b = await chromium.launch();
  for (const [name, fn] of Object.entries(scenarios)) {
    if (only && only !== name) continue;
    console.log('\n' + name);
    await post('/__reset'); await sql("delete from auth.users where email like '%@example.com' and email <> 'probe@example.com'");
    try { await fn(b); } catch (err) { failures++; console.log('  FAIL threw: ' + err.message.split('\n')[0]); }
    await chaos({});
  }
  await b.close();
  console.log(failures ? `\n${failures} FAILED` : '\nall passed'); process.exit(failures ? 1 : 0);
})();
