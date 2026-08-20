#!/usr/bin/env node
/**
 * Reference backend for Option A (backend-side matching).
 * Zero npm dependencies - plain Node.js (>= 18).
 *
 * Architecture:
 *
 *   terminal (ZK sensor)                matcher agent (Android box w/ this plugin)
 *   startScanner() ── POST /scan ──▶  THIS SERVER  ── POST /identify ──▶ /identify
 *   posts template on each press        (stores templates,               (ZKFingerService.verify)
 *                                      calls the agent,
 *                                      returns match verdict)
 *
 * Run:
 *   PORT=3000 MATCHER_URL=http://192.168.1.50:8787 AGENT_TOKEN= node backend/server.js
 *
 * Quick test:
 *   # enroll a template (paste a real base64 JQSS21 template)
 *   curl -s localhost:3000/enroll -d '{"user_id":"42","template":"SlFTUzIx..."}'
 *   # scan: server asks the agent to compare against all stored templates
 *   curl -s localhost:3000/scan -d '{"template":"SlFTUzIx...","device":"gate-1"}'
 *   curl -s localhost:3000/users            # list (truncated)
 *   curl -s localhost:3000/health
 */
'use strict';

const http = require('http');
const { URL } = require('url');

const PORT = Number(process.env.PORT || 3000);
const MATCHER_URL = process.env.MATCHER_URL || ''; // e.g. http://192.168.1.50:8787
const AGENT_TOKEN = process.env.AGENT_TOKEN || ''; // optional shared secret
const MATCH_THRESHOLD = Number(process.env.MATCH_THRESHOLD || 70);

// ---------- tiny JSON file store (swap for Postgres/Mongo in production) ----
const fs = require('fs');
const STORE_PATH = process.env.STORE_PATH || `${__dirname}/store.json`;

/** @type {Map<string,string>} userId -> base64 template */
let users;
try {
  users = new Map(Object.entries(JSON.parse(fs.readFileSync(STORE_PATH, 'utf8'))));
} catch {
  users = new Map();
}

let saveTimer = null;
function persist() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(STORE_PATH, JSON.stringify(Object.fromEntries(users)), () => {});
  }, 250);
}

/** @type {Array<object>} append-only audit log of scans */
const scans = [];

// ------------------------------ matcher agent ------------------------------
function callAgent(path, body) {
  return new Promise((resolve, reject) => {
    if (!MATCHER_URL) return reject(new Error('MATCHER_URL not configured'));
    const url = new URL(path, MATCHER_URL);
    const payload = JSON.stringify(body);
    const req = http.request(
      url,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
          ...(AGENT_TOKEN ? { 'x-agent-token': AGENT_TOKEN } : {}),
        },
        timeout: 30000,
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          try {
            resolve({ status: res.statusCode, body: JSON.parse(data || '{}') });
          } catch (e) {
            reject(e);
          }
        });
      }
    );
    req.on('timeout', () => req.destroy(new Error('agent timeout')));
    req.on('error', reject);
    req.end(payload);
  });
}

/** Ask the agent to identify `template` against all stored templates. */
async function matchAgainstAll(template) {
  if (users.size === 0) return { match: false, user_id: null, score: 0, checked: 0 };
  const candidates = Object.fromEntries(users); // {userId: template}
  const r = await callAgent('/identify', { template, candidates });
  if (r.status !== 200) throw new Error(`agent responded ${r.status}: ${JSON.stringify(r.body)}`);
  return r.body; // {match, user_id, score, checked}
}

// ------------------------------- HTTP helpers ------------------------------
function readJson(req, limit = 64 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) return reject(new Error('body too large'));
      chunks.push(c);
    });
    req.on('end', () => {
      try {
        const text = Buffer.concat(chunks).toString('utf8');
        resolve(text ? JSON.parse(text) : {});
      } catch (e) {
        reject(new Error('invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  });
  res.end(body);
}

// --------------------------------- routes ----------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const route = `${req.method} ${url.pathname}`;

  try {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': '*',
        'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      });
      return res.end();
    }

    if (route === 'GET /health') {
      return send(res, 200, {
        ok: true,
        users: users.size,
        scans: scans.length,
        matcher_configured: Boolean(MATCHER_URL),
      });
    }

    // --- enroll: store a template captured by a terminal in scanner mode ---
    if (route === 'POST /enroll') {
      const body = await readJson(req);
      const userId = String(body.user_id || '').trim();
      const template = String(body.template || '');
      if (!userId || !template) {
        return send(res, 400, { error: 'user_id and template required' });
      }
      if (template.length < 500) {
        return send(res, 400, { error: 'template looks too short / invalid' });
      }
      const existed = users.has(userId);
      users.set(userId, template);
      persist();
      return send(res, existed ? 200 : 201, { ok: true, user_id: userId, updated: existed });
    }

    // --- scan: terminal pressed a finger; identify via the matcher agent ---
    if (route === 'POST /scan') {
      const body = await readJson(req);
      const template = String(body.template || '');
      if (!template) return send(res, 400, { error: 'template required' });

      let verdict;
      try {
        verdict = await matchAgainstAll(template);
      } catch (e) {
        return send(res, 502, { error: 'matcher agent failed', detail: e.message });
      }

      const record = {
        at: new Date().toISOString(),
        device: body.device || null,
        purpose: body.purpose || 'identify',
        match: Boolean(verdict.match && (verdict.score ?? 0) > MATCH_THRESHOLD),
        user_id: verdict.user_id || null,
        score: verdict.score ?? 0,
        checked: verdict.checked ?? 0,
      };
      scans.push(record);
      if (scans.length > 5000) scans.shift();

      return send(res, 200, record);
    }

    // --- utility routes ---
    if (route === 'GET /users') {
      return send(res, 200, {
        count: users.size,
        users: [...users.keys()].map((id) => ({
          user_id: id,
          template_chars: users.get(id).length,
        })),
      });
    }

    if (route === 'GET /users.json') {
      // full templates - for syncing terminals (hybrid fallback / backup)
      return send(res, 200, Object.fromEntries(users));
    }

    if (route === 'GET /scans') {
      return send(res, 200, { scans: scans.slice(-100).reverse() });
    }

    if (route === 'DELETE /users') {
      users.clear();
      persist();
      return send(res, 200, { ok: true });
    }

    return send(res, 404, { error: 'not found', route });
  } catch (e) {
    return send(res, e.message === 'invalid JSON' || e.message === 'body too large' ? 400 : 500, {
      error: e.message,
    });
  }
});

server.listen(PORT, () => {
  console.log(`[backend] listening on http://0.0.0.0:${PORT}`);
  console.log(`[backend] MATCHER_URL = ${MATCHER_URL || '(NOT SET - /scan will fail)'}`);
  console.log(`[backend] store = ${STORE_PATH}`);
  if (MATCHER_URL) {
    http
      .get(new URL('/health', MATCHER_URL), (r) => {
        console.log(`[backend] matcher agent reachable (status ${r.statusCode})`);
      })
      .on('error', (e) => {
        console.warn(`[backend] WARNING: cannot reach matcher agent: ${e.message}`);
      });
  }
});