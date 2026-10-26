// API tests with an in-memory repository (no database needed in CI): npm test
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createHandler, hashPassword, verifyPassword } = require('../src/app');

function memoryRepo() {
  const posts = new Map();
  let next = 1;
  return {
    config: { host: 'memory', port: 0, database: 'board', user: 'test', password: 'x' },
    async list({ q, page, perPage }) {
      const all = [...posts.values()].filter((p) => !q || p.title.includes(q) || p.content.includes(q))
        .sort((a, b) => b.id - a.id);
      return { total: all.length, items: all.slice((page - 1) * perPage, page * perPage) };
    },
    async get(id, { countView } = {}) {
      const p = posts.get(id);
      if (p && countView) p.views += 1;
      return p ? { ...p } : null;
    },
    async create(p) { const id = next++; posts.set(id, { id, views: 0, ...p }); return id; },
    async update(id, p) { Object.assign(posts.get(id), p); },
    async remove(id) { posts.delete(id); },
    async check() { return { serverVersion: 'memory', posts: posts.size }; },
  };
}

async function withServer(fn) {
  const server = http.createServer(createHandler(memoryRepo()));
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, body) => {
    const res = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json' },
                                           body: body && JSON.stringify(body) });
    const text = await res.text();
    return { status: res.status, body: text && res.headers.get('content-type')?.includes('json') ? JSON.parse(text) : text };
  };
  try { await fn(call); } finally { server.close(); }
}

test('password hash round trip', () => {
  const h = hashPassword('1234');
  assert.ok(verifyPassword('1234', h));
  assert.ok(!verifyPassword('9999', h));
});

test('healthz and dbcheck', () => withServer(async (call) => {
  assert.deepEqual(await call('GET', '/healthz'), { status: 200, body: 'ok' });
  const r = await call('GET', '/api/dbcheck');
  assert.equal(r.status, 200);
  assert.equal(r.body.status, 'ok');
}));

test('create, view, update, delete with password', () => withServer(async (call) => {
  assert.equal((await call('POST', '/api/posts', { title: '', author: 'a', content: 'c', password: '1' })).status, 400);
  const created = await call('POST', '/api/posts', { title: '첫 글', author: '홍길동', content: '내용', password: '1234' });
  assert.equal(created.status, 201);
  const id = created.body.id;

  const view = await call('GET', `/api/posts/${id}`);
  assert.equal(view.body.views, 1);
  assert.equal(view.body.passwordHash, undefined);

  assert.equal((await call('PUT', `/api/posts/${id}`, { title: 'x', author: 'y', content: 'z', password: '0000' })).status, 403);
  const updated = await call('PUT', `/api/posts/${id}`, { title: '수정', author: 'y', content: 'z', password: '1234' });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.title, '수정');

  const list = await call('GET', '/api/posts?q=%EC%88%98%EC%A0%95');
  assert.equal(list.body.total, 1);

  assert.equal((await call('DELETE', `/api/posts/${id}`, { password: '0000' })).status, 403);
  assert.equal((await call('DELETE', `/api/posts/${id}`, { password: '1234' })).status, 204);
  assert.equal((await call('GET', `/api/posts/${id}`)).status, 404);
}));

test('paging', () => withServer(async (call) => {
  for (let i = 1; i <= 12; i++) {
    await call('POST', '/api/posts', { title: `t${i}`, author: 'a', content: 'c', password: '1234' });
  }
  const p2 = await call('GET', '/api/posts?page=2');
  assert.equal(p2.body.pages, 2);
  assert.equal(p2.body.items.length, 2);
  assert.equal((await call('GET', '/api/posts?page=9')).body.page, 2);
}));
