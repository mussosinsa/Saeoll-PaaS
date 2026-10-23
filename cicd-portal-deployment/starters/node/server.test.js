const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const { handler } = require('./server');

test('GET /healthz returns ok', async () => {
  const server = http.createServer(handler).listen(0);
  const { port } = server.address();
  const body = await new Promise((resolve, reject) => {
    http.get({ port, path: '/healthz' }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
  server.close();
  assert.strictEqual(body, 'ok');
});
