// A stand-in for the two Supabase services the app talks to, in front of the
// REAL club database:
//   REST (PostgREST):  POST /rest/v1/rpc/<function>, GET /rest/v1/<table>
//   Sign-in (GoTrue):  /auth/v1/otp, /verify, /token, /logout, /user
// It does what the real ones do for the club: checks the JWT, becomes the
// "authenticated" (or "anon") database role with the member's claims, runs
// the call in one transaction, and returns Postgres errors as PostgREST does.
// What it adds is misbehaviour on demand (POST /__chaos), the way a bad
// connection does: failures, slowness, and replies lost AFTER the work is done.
//
// Local testing only. It binds to 127.0.0.1 and signs tokens with a fixed secret.
const http = require('http');
const crypto = require('crypto');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT || 54321);
const DB = process.env.CLUB_E2E_DB || 'club_e2e';
const SECRET = 'local-e2e-secret-local-e2e-secret-0123456789';
const pool = new Pool({
  database: DB, max: 30,
  user: process.env.PGUSER || require('os').userInfo().username,
  host: process.env.PGHOST || '/var/run/postgresql',   // local socket by default
});

const chaos0 = { failRate: 0, failStatus: 503, loseReplyRate: 0, delayMs: 0, jitterMs: 0, jwtTtl: 3600, only: null };
let chaos = { ...chaos0 };
let stats = { requests: 0, failed: 0, lostReplies: 0, byPath: {} };
const codes = new Map();
const refreshTokens = new Map();

const b64 = (b) => Buffer.from(b).toString('base64url');
const sign = (payload) => {
  const h = b64(JSON.stringify({ alg: 'HS256', typ: 'JWT' })), p = b64(JSON.stringify(payload));
  return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`;
};
function verify(token) {
  const parts = token.split('.');
  if (parts.length !== 3) return null; // not a JWT: the publishable key
  const good = crypto.createHmac('sha256', SECRET).update(`${parts[0]}.${parts[1]}`).digest('base64url');
  if (good !== parts[2]) throw Object.assign(new Error('JWSError JWSInvalidSignature'), { status: 401, pg: 'PGRST301' });
  const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
  if (claims.exp && claims.exp < Date.now() / 1000) throw Object.assign(new Error('JWT expired'), { status: 401, pg: 'PGRST301' });
  return claims;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readBody = (req) => new Promise((res) => { let d = ''; req.on('data', (c) => (d += c)); req.on('end', () => res(d)); });
const send = (res, status, body, type = 'application/json') => {
  res.writeHead(status, { 'content-type': type });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
};

async function asRole(claims, fn) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    await c.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    await c.query(`set local role ${claims.role === 'authenticated' ? 'authenticated' : 'anon'}`);
    const r = await fn(c);
    await c.query('commit');
    return r;
  } catch (e) {
    await c.query('rollback').catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

function pgError(e, anon) {
  if (e.pg) return { status: e.status, body: { code: e.pg, message: e.message, details: null, hint: null } };
  const state = e.code || 'XX000';
  let status = 400;
  if (state === '42501') status = anon ? 401 : 403;
  else if (state === '28000') status = 401;
  else if (state.startsWith('53') || state.startsWith('57') || state.startsWith('08')) status = 503;
  return { status, body: { code: state, message: e.message, details: e.detail || null, hint: e.hint || null } };
}

const fnCache = new Map();
async function fnInfo(name) {
  if (fnCache.has(name)) return fnCache.get(name);
  const { rows } = await pool.query(
    `select p.proretset, p.pronargs, coalesce(p.proargnames[1:p.pronargs], '{}') as args
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = $1 and p.prokind = 'f'`, [name]);
  const info = rows[0] || null;
  fnCache.set(name, info);
  return info;
}

async function rpc(name, body, claims) {
  const info = await fnInfo(name);
  const args = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  const keys = Object.keys(args);
  if (!info || keys.some((k) => !info.args.includes(k))) {
    // PostgREST answers 404 PGRST202 when no function matches the names it was given.
    return { status: 404, body: { code: 'PGRST202', message: `Could not find the function public.${name}(${keys.join(', ')}) in the schema cache`, details: null, hint: null } };
  }
  const named = keys.map((k, i) => `${k} => $${i + 1}`).join(', ');
  const sql = info.proretset
    ? `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) as r from public.${name}(${named}) t`
    : `select to_jsonb(public.${name}(${named})) as r`;
  const rows = await asRole(claims, (c) => c.query(sql, keys.map((k) => args[k])));
  return { status: 200, body: rows.rows[0].r };
}

async function table(name, params, claims) {
  if (!/^[a-z_]+$/.test(name)) return { status: 404, body: { code: 'PGRST205', message: 'not found' } };
  const where = [], vals = [];
  const ops = { eq: '=', gte: '>=', lte: '<=', gt: '>', lt: '<' };
  for (const [k, v] of params) {
    if (['select', 'order', 'limit', 'offset'].includes(k) || !/^[a-z_]+$/.test(k)) continue;
    const m = /^(eq|gte|lte|gt|lt)\.(.*)$/.exec(v);
    if (m) { vals.push(m[2]); where.push(`"${k}" ${ops[m[1]]} $${vals.length}`); }
  }
  const order = (params.get('order') || '').split(',').filter(Boolean).map((o) => {
    const [col, dir] = o.split('.');
    return /^[a-z_]+$/.test(col) ? `"${col}" ${dir === 'desc' ? 'desc' : 'asc'}` : null;
  }).filter(Boolean);
  const limit = Math.min(Number(params.get('limit')) || 1000, 1000);
  const sql = `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) as r from (select * from public."${name}" ${where.length ? 'where ' + where.join(' and ') : ''} ${order.length ? 'order by ' + order.join(',') : ''} limit ${limit}) t`;
  const rows = await asRole(claims, (c) => c.query(sql, vals));
  return { status: 200, body: rows.rows[0].r };
}

function sessionFor(user) {
  const now = Math.floor(Date.now() / 1000), exp = now + chaos.jwtTtl;
  const access = sign({ aud: 'authenticated', exp, iat: now, sub: user.id, email: user.email, role: 'authenticated', aal: 'aal1', session_id: crypto.randomUUID() });
  const refresh = crypto.randomBytes(9).toString('base64url');
  refreshTokens.set(refresh, user);
  const iso = new Date().toISOString();
  return {
    access_token: access, token_type: 'bearer', expires_in: chaos.jwtTtl, expires_at: exp, refresh_token: refresh,
    user: { id: user.id, aud: 'authenticated', role: 'authenticated', email: user.email, email_confirmed_at: iso, app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {}, identities: [], created_at: iso, updated_at: iso },
  };
}

async function auth(path, req, body, url) {
  if (path === '/auth/v1/otp') {
    if (!body.email) return { status: 422, body: { code: 422, error_code: 'validation_failed', msg: 'To signup, please provide your email' } };
    codes.set(body.email.toLowerCase(), '123456');
    return { status: 200, body: {} };
  }
  if (path === '/auth/v1/verify') {
    const email = String(body.email || '').toLowerCase();
    if (!codes.has(email) || codes.get(email) !== String(body.token)) return { status: 403, body: { code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' } };
    let { rows } = await pool.query('select id, email from auth.users where email = $1', [email]);
    if (!rows[0]) ({ rows } = await pool.query('insert into auth.users (email) values ($1) returning id, email', [email]));
    if (email.includes('staff')) await pool.query('insert into public.staff (user_id) values ($1) on conflict do nothing', [rows[0].id]);
    return { status: 200, body: sessionFor(rows[0]) };
  }
  if (path === '/auth/v1/token') {
    const user = refreshTokens.get(body.refresh_token);
    if (!user) return { status: 400, body: { code: 400, error_code: 'refresh_token_not_found', msg: 'Invalid Refresh Token: Refresh Token Not Found' } };
    refreshTokens.delete(body.refresh_token);
    return { status: 200, body: sessionFor(user) };
  }
  if (path === '/auth/v1/logout') return { status: 204, body: '' };
  if (path === '/auth/v1/user') {
    const claims = verify((req.headers.authorization || '').replace(/^Bearer /i, ''));
    return claims ? { status: 200, body: { id: claims.sub, email: claims.email, aud: 'authenticated', role: 'authenticated' } } : { status: 401, body: { code: 401, msg: 'missing sub claim' } };
  }
  return { status: 404, body: { code: 404, msg: 'not found' } };
}

async function control(path, req, body, res) {
  if (path === '/__chaos') {
    if (req.method === 'POST') chaos = { ...chaos0, ...body };
    return send(res, 200, chaos);
  }
  if (path === '/__reset') { chaos = { ...chaos0 }; stats = { requests: 0, failed: 0, lostReplies: 0, byPath: {} }; codes.clear(); return send(res, 200, {}); }
  if (path === '/__stats') return send(res, 200, stats);
  if (path === '/__sql') {
    try { const r = await pool.query(body.sql, body.params || []); return send(res, 200, { rows: r.rows }); }
    catch (e) { return send(res, 400, { error: e.message }); }
  }
  return send(res, 404, {});
}

http.createServer(async (req, res) => {
  const origin = req.headers.origin || '*';
  res.setHeader('access-control-allow-origin', origin);
  res.setHeader('access-control-allow-headers', req.headers['access-control-request-headers'] || '*');
  res.setHeader('access-control-allow-methods', 'GET,POST,PATCH,PUT,DELETE,OPTIONS');
  res.setHeader('access-control-expose-headers', 'content-range');
  res.setHeader('vary', 'origin');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const url = new URL(req.url, 'http://x');
  const raw = await readBody(req);
  let body = {};
  try { body = raw ? JSON.parse(raw) : {}; } catch { body = {}; }
  if (url.pathname.startsWith('/__')) return control(url.pathname, req, body ?? {}, res);

  stats.requests++;
  stats.byPath[url.pathname] = (stats.byPath[url.pathname] || 0) + 1;
  if (chaos.delayMs || chaos.jitterMs) await sleep(chaos.delayMs + Math.random() * chaos.jitterMs);
  const hit = !chaos.only || new RegExp(chaos.only).test(url.pathname);
  if (hit && Math.random() < chaos.failRate) {
    stats.failed++;
    return send(res, chaos.failStatus, 'Service Unavailable', 'text/plain');
  }

  let out;
  try {
    if (url.pathname.startsWith('/auth/v1/')) {
      out = await auth(url.pathname, req, body ?? {}, url);
    } else if (url.pathname.startsWith('/rest/v1/')) {
      const token = (req.headers.authorization || '').replace(/^Bearer /i, '');
      let claims = null, anon = false;
      try { claims = verify(token); } catch (e) { out = pgError(e, true); }
      if (!out) {
        if (!claims) { claims = { role: 'anon' }; anon = true; }
        const rest = url.pathname.slice('/rest/v1/'.length);
        out = rest.startsWith('rpc/') ? await rpc(rest.slice(4), body, claims).catch((e) => pgError(e, anon)) : await table(rest, url.searchParams, claims).catch((e) => pgError(e, anon));
      }
    } else out = { status: 404, body: {} };
  } catch (e) { out = pgError(e, false); }

  // The work is done. A bad connection can still lose the reply.
  if (hit && Math.random() < chaos.loseReplyRate) {
    stats.lostReplies++;
    return req.socket.destroy();
  }
  send(res, out.status, out.body === '' ? '' : out.body);
}).listen(PORT, '127.0.0.1', () => console.log(`club e2e server on http://127.0.0.1:${PORT} (database ${DB})`));
