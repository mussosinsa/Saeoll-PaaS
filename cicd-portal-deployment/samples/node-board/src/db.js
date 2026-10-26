// MariaDB repository for the board. Connection settings come from environment variables
// (Kubernetes Secret <app>-db via envFrom): DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD.
const mariadb = require('mariadb');

const SCHEMA = `CREATE TABLE IF NOT EXISTS posts (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  title         VARCHAR(200) NOT NULL,
  content       TEXT         NOT NULL,
  author        VARCHAR(50)  NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  views         INT UNSIGNED NOT NULL DEFAULT 0,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    DATETIME     NULL     ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`;

function dbConfig(env = process.env) {
  return {
    host: env.DB_HOST || '127.0.0.1',
    port: Number(env.DB_PORT || 3306),
    database: env.DB_NAME || 'board',
    user: env.DB_USER || 'board',
    password: env.DB_PASSWORD || '',
  };
}

function toPost(row) {
  return row && {
    id: Number(row.id),
    title: row.title,
    content: row.content,
    author: row.author,
    views: Number(row.views),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    passwordHash: row.password_hash,
  };
}

// The pool connects lazily: the web server starts (and /healthz answers) even while the DB is down.
function createRepository(config = dbConfig()) {
  const pool = mariadb.createPool({ ...config, connectionLimit: 5, connectTimeout: 5000, acquireTimeout: 7000,
                                    dateStrings: true, bigIntAsNumber: true });
  let schemaReady = null;
  async function query(sql, params) {
    if (!schemaReady) {
      schemaReady = pool.query(SCHEMA).catch((err) => { schemaReady = null; throw err; });
    }
    await schemaReady;
    return pool.query(sql, params);
  }

  return {
    config,
    async list({ q = '', page = 1, perPage = 10 }) {
      const where = q ? 'WHERE title LIKE ? OR content LIKE ?' : '';
      const like = `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
      const params = q ? [like, like] : [];
      const [{ total }] = await query(`SELECT COUNT(*) AS total FROM posts ${where}`, params);
      const rows = await query(
        `SELECT id, title, author, views, created_at FROM posts ${where} ORDER BY id DESC LIMIT ? OFFSET ?`,
        [...params, perPage, (page - 1) * perPage]);
      return { total: Number(total), items: rows.map(toPost) };
    },
    async get(id, { countView = false } = {}) {
      if (countView) await query('UPDATE posts SET views = views + 1, updated_at = updated_at WHERE id = ?', [id]);
      const rows = await query('SELECT * FROM posts WHERE id = ?', [id]);
      return toPost(rows[0]) || null;
    },
    async create({ title, content, author, passwordHash }) {
      const r = await query('INSERT INTO posts (title, content, author, password_hash) VALUES (?, ?, ?, ?)',
                            [title, content, author, passwordHash]);
      return Number(r.insertId);
    },
    async update(id, { title, content, author }) {
      await query('UPDATE posts SET title = ?, content = ?, author = ? WHERE id = ?', [title, content, author, id]);
    },
    async remove(id) {
      await query('DELETE FROM posts WHERE id = ?', [id]);
    },
    async check() {
      const [{ version }] = await query('SELECT VERSION() AS version');
      const [{ posts }] = await query('SELECT COUNT(*) AS posts FROM posts');
      return { serverVersion: version, posts: Number(posts) };
    },
    end: () => pool.end(),
  };
}

module.exports = { createRepository, dbConfig };
