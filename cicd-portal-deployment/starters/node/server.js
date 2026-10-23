// Minimal HTTP service: GET / and GET /healthz on port 8080.
const http = require('node:http');

function handler(req, res) {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('ok');
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ app: '{APP}', vendor: '{VENDOR}', time: new Date().toISOString() }));
}

if (require.main === module) {
  const port = Number(process.env.PORT || 8080);
  http.createServer(handler).listen(port, () => console.log(`listening on ${port}`));
}

module.exports = { handler };
