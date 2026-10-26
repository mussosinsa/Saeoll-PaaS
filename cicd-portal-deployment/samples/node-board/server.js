// Board REST API on port 8080 (see src/app.js for the routes).
const http = require('node:http');
const { createHandler } = require('./src/app');
const { createRepository } = require('./src/db');

const repo = createRepository();
const server = http.createServer(createHandler(repo));
const port = Number(process.env.PORT || 8080);
server.listen(port, () => {
  const c = repo.config;
  console.log(`node-board listening on ${port} (DB ${c.user}@${c.host}:${c.port}/${c.database})`);
});

function shutdown() {
  server.close(() => repo.end().finally(() => process.exit(0)));
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
