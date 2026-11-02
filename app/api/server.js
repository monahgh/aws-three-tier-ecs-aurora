// Items API (Node.js, no framework). Injected into a public node image at startup.
// Writes go through the RDS Proxy read/write endpoint (Aurora writer),
// reads through the proxy READ_ONLY endpoint (Aurora reader).
//
//   GET  /api/health  -> 200 without touching the DB (a DB failover must not make the ALB kill every task)
//   GET  /api/items   -> latest 50 items, from the reader
//   POST /api/items   -> {"name": "..."} inserted on the writer
//   GET  /api/whoami  -> which Aurora instance serves each endpoint (shows the read/write split)

const http = require('http');
const os = require('os');
const { Pool } = require('pg');

const PORT = Number(process.env.PORT || 3000);

const base = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  port: 5432,
  // RDS Proxy requires TLS. Lab: encrypt without verifying the certificate.
  // Prod: set DB_SSL_REJECT_UNAUTHORIZED=true (and supply the CA bundle if needed).
  ssl: { rejectUnauthorized: process.env.DB_SSL_REJECT_UNAUTHORIZED === 'true' },
  max: 5,
  connectionTimeoutMillis: 5000,
  idleTimeoutMillis: 30000,
};

const writer = new Pool({ ...base, host: process.env.DB_HOST_RW });
const reader = new Pool({ ...base, host: process.env.DB_HOST_RO });

// Idle connections can be dropped during a failover: log it, do not crash the process.
writer.on('error', (e) => console.error('writer pool error:', e.message));
reader.on('error', (e) => console.error('reader pool error:', e.message));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ensureSchema() {
  for (;;) {
    try {
      await writer.query(`
        CREATE TABLE IF NOT EXISTS items (
          id         bigserial PRIMARY KEY,
          name       text        NOT NULL,
          created_at timestamptz NOT NULL DEFAULT now()
        )`);
      console.log('schema ready');
      return;
    } catch (e) {
      console.error('schema init failed, retrying in 5s:', e.message);
      await sleep(5000);
    }
  }
}

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
      if (data.length > 10000) reject(new Error('body too large'));
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

// aurora_db_instance_identifier() is an Aurora PostgreSQL function: the instance name.
const WHOAMI_SQL = `
  SELECT aurora_db_instance_identifier() AS instance,
         inet_server_addr()::text         AS server_ip,
         pg_is_in_recovery()              AS is_reader`;

const server = http.createServer(async (req, res) => {
  const { pathname } = new URL(req.url, 'http://localhost');
  try {
    if (pathname === '/api/health') {
      return send(res, 200, { status: 'ok', task: os.hostname() });
    }

    if (pathname === '/api/items' && req.method === 'GET') {
      const r = await reader.query('SELECT id, name, created_at FROM items ORDER BY id DESC LIMIT 50');
      return send(res, 200, r.rows);
    }

    if (pathname === '/api/items' && req.method === 'POST') {
      const body = JSON.parse((await readBody(req)) || '{}');
      const name = String(body.name || '').trim().slice(0, 200);
      if (!name) return send(res, 400, { error: 'name is required' });
      const r = await writer.query(
        'INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at',
        [name]
      );
      return send(res, 201, r.rows[0]);
    }

    if (pathname === '/api/whoami') {
      const [w, r] = await Promise.all([writer.query(WHOAMI_SQL), reader.query(WHOAMI_SQL)]);
      return send(res, 200, {
        task: os.hostname(),
        read_write_endpoint: { host: process.env.DB_HOST_RW, ...w.rows[0] },
        read_only_endpoint: { host: process.env.DB_HOST_RO, ...r.rows[0] },
      });
    }

    return send(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(req.method, pathname, e.message);
    return send(res, 503, { error: e.message });
  }
});

server.listen(PORT, () => console.log(`api listening on ${PORT}, task ${os.hostname()}`));
ensureSchema();

// ECS sends SIGTERM on scale-in/deploy: stop accepting, close pools, exit.
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, shutting down');
  server.close();
  await Promise.allSettled([writer.end(), reader.end()]);
  process.exit(0);
});
