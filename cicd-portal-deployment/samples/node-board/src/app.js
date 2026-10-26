// Board REST API (shared contract with samples/spring-board, used by samples/vue-board):
//   GET    /api/posts?q=&page=      list  {total, page, pages, items[]}
//   GET    /api/posts/:id           view  (views + 1)
//   POST   /api/posts               create {title, author, password, content} -> 201 {id}
//   PUT    /api/posts/:id           update {title, author, content, password}
//   DELETE /api/posts/:id           delete {password}
//   GET    /api/dbcheck             DB connection check (JSON)
//   GET    /healthz                 Kubernetes probe, never touches the DB
const crypto = require('node:crypto');

const PER_PAGE = 10;
const MAX_BODY = 64 * 1024;

function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(password, salt, 32);
  return `scrypt$${salt.toString('hex')}$${hash.toString('hex')}`;
}

function verifyPassword(password, stored) {
  const [scheme, saltHex, hashHex] = String(stored).split('$');
  if (scheme !== 'scrypt' || !saltHex || !hashHex) return false;
  const expected = Buffer.from(hashHex, 'hex');
  const actual = crypto.scryptSync(String(password), Buffer.from(saltHex, 'hex'), expected.length);
  return crypto.timingSafeEqual(actual, expected);
}

function validate(body, needPassword) {
  const v = {};
  for (const f of ['title', 'author', 'content', 'password']) v[f] = String(body?.[f] ?? '').trim();
  const errors = [];
  if (!v.title || v.title.length > 200) errors.push('제목은 1~200자로 입력하세요.');
  if (!v.author || v.author.length > 50) errors.push('작성자는 1~50자로 입력하세요.');
  if (!v.content || v.content.length > 10000) errors.push('내용은 1~10,000자로 입력하세요.');
  if (needPassword && (v.password.length < 4 || v.password.length > 64)) errors.push('비밀번호는 4~64자로 입력하세요.');
  return { v, errors };
}

function publicPost(p) {
  const { passwordHash, ...rest } = p; // never return the hash
  return rest;
}

// MariaDB error -> hint (same wording as samples/php-board)
function dbErrorHint(err) {
  const code = err?.errno;
  if (code === 1045) return '1045 사용자 또는 비밀번호 오류 (DB_USER / DB_PASSWORD)';
  if (code === 1049) return '1049 데이터베이스 없음 (DB_NAME)';
  if (['ECONNREFUSED', 'ETIMEDOUT', 'ER_GET_CONNECTION_TIMEOUT', 'ER_CONNECTION_TIMEOUT'].includes(err?.code)) {
    return '2002 서버에 접속할 수 없음 (DB_HOST / DB_PORT, MariaDB Pod 상태)';
  }
  if (err?.code === 'ENOTFOUND') return '2005 호스트 이름을 찾을 수 없음 (DB_HOST)';
  return err?.message || String(err);
}

function send(res, status, body) {
  if (body === undefined) {
    res.writeHead(status);
    return res.end();
  }
  const text = typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': typeof body === 'string' ? 'text/plain; charset=utf-8'
                                                                    : 'application/json; charset=utf-8' });
  return res.end(text);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('body too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(Object.assign(new Error('invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

function createHandler(repo, { appName = process.env.APP_NAME || 'node-board' } = {}) {
  return async function handler(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';
    const m = path.match(/^\/api\/posts\/(\d+)$/);
    try {
      if (path === '/healthz') return send(res, 200, 'ok');
      if (path === '/' && req.method === 'GET') {
        return send(res, 200, { app: appName, api: '/api/posts', dbcheck: '/api/dbcheck' });
      }
      if (path === '/api/dbcheck' && req.method === 'GET') {
        const c = repo.config || {};
        const base = { db_host: c.host, db_port: c.port, db_name: c.database, db_user: c.user, password_set: !!c.password };
        try {
          const started = Date.now();
          const r = await repo.check();
          return send(res, 200, { ...base, status: 'ok', server_version: r.serverVersion, posts: r.posts,
                                  elapsed_ms: Date.now() - started });
        } catch (err) {
          console.error('[node-board] dbcheck:', err.message);
          return send(res, 503, { ...base, status: 'error', error: dbErrorHint(err) });
        }
      }
      if (path === '/api/posts' && req.method === 'GET') {
        const q = (url.searchParams.get('q') || '').trim();
        let page = Math.max(1, parseInt(url.searchParams.get('page'), 10) || 1);
        let r = await repo.list({ q, page, perPage: PER_PAGE });
        const pages = Math.max(1, Math.ceil(r.total / PER_PAGE));
        if (page > pages) { page = pages; r = await repo.list({ q, page, perPage: PER_PAGE }); }
        return send(res, 200, { total: r.total, page, pages, items: r.items.map(publicPost) });
      }
      if (path === '/api/posts' && req.method === 'POST') {
        const { v, errors } = validate(await readJson(req), true);
        if (errors.length) return send(res, 400, { errors });
        const id = await repo.create({ title: v.title, content: v.content, author: v.author,
                                       passwordHash: hashPassword(v.password) });
        return send(res, 201, { id });
      }
      if (m) {
        const id = Number(m[1]);
        if (req.method === 'GET') {
          const post = await repo.get(id, { countView: true });
          return post ? send(res, 200, publicPost(post)) : send(res, 404, { errors: ['글을 찾을 수 없습니다.'] });
        }
        if (req.method === 'PUT' || req.method === 'DELETE') {
          const body = await readJson(req);
          const post = await repo.get(id);
          if (!post) return send(res, 404, { errors: ['글을 찾을 수 없습니다.'] });
          if (!verifyPassword(body?.password ?? '', post.passwordHash)) {
            return send(res, 403, { errors: ['비밀번호가 일치하지 않습니다.'] });
          }
          if (req.method === 'DELETE') {
            await repo.remove(id);
            return send(res, 204);
          }
          const { v, errors } = validate(body, false);
          if (errors.length) return send(res, 400, { errors });
          await repo.update(id, { title: v.title, content: v.content, author: v.author });
          return send(res, 200, publicPost(await repo.get(id)));
        }
      }
      return send(res, 404, { errors: ['not found'] });
    } catch (err) {
      if (err.status) return send(res, err.status, { errors: [err.message] });
      console.error('[node-board] database error:', err.message);
      return send(res, 503, { errors: ['데이터베이스에 연결할 수 없습니다.'], cause: dbErrorHint(err) });
    }
  };
}

module.exports = { createHandler, hashPassword, verifyPassword };
