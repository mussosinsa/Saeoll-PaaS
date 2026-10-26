// Board REST API client (/api is proxied by nginx to node-board or spring-board in the same namespace).
export class ApiError extends Error {
  constructor(status, body) {
    const messages = body?.errors || [body?.error || `HTTP ${status}`];
    super(messages.join(' '));
    this.status = status;
    this.messages = messages;
    this.cause = body?.cause;
  }
}

async function call(method, path, body) {
  const res = await fetch(`/api${path}`, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { error: text.slice(0, 200) }; }
  if (!res.ok) {
    if (res.status === 502 || res.status === 504) {
      data = { errors: ['API 서버에 연결할 수 없습니다 (nginx → API_UPSTREAM 확인).'] };
    }
    throw new ApiError(res.status, data);
  }
  return data;
}

export const api = {
  list: (q, page) => call('GET', `/posts?q=${encodeURIComponent(q || '')}&page=${page || 1}`),
  get: (id) => call('GET', `/posts/${id}`),
  create: (post) => call('POST', '/posts', post),
  update: (id, post) => call('PUT', `/posts/${id}`, post),
  remove: (id, password) => call('DELETE', `/posts/${id}`, { password }),
  dbcheck: () => call('GET', '/dbcheck'),
};
