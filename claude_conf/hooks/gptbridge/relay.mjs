#!/usr/bin/env node
// relay.mjs — T2 ChatGPT-session consult relay (design §4).
//
// A tiny loopback MCP server (Streamable HTTP, JSON-response mode) that ChatGPT
// reaches as a developer-mode connector THROUGH a cloudflared quick tunnel. It
// exposes EXACTLY TWO tools and NOTHING else — no file read, no search, no exec,
// no session transcript. Its whole job is message-passing:
//
//   consult_claude(question, context?)  ChatGPT asks this Claude Code session a
//       question. The question is injected AS a2a peer traffic (gptbridge.sh
//       ingest → classify-inbound: SIF/quarantine, dedup, Stop-gate surface,
//       sticky-deny) — it lands as UNTRUSTED, quarantined DATA the owner
//       approves in the live session. We sync-wait up to sync_wait_s for an
//       owner-approved reply, else return {queued, consult_id}.
//   check_relay()  ChatGPT PULLS: owner-approved replies to earlier consults AND
//       Claude-initiated questions (design §4.5 — ChatGPT can't be pushed to).
//
// SECURITY: auth is a per-start capability-URL token in the path (POST
// /mcp/<token>); any other path/token 404s; an optional Authorization: Bearer
// is honored (constant-time compare). Binds 127.0.0.1 only — cloudflared is the
// sole ingress. A leaked URL yields only: drop questions into a bannered,
// quarantined inbox + steal not-yet-fetched reply text (single-delivery bounds
// it). No reads, no exec. That is the ENTIRE blast radius.
//
// Zero runtime deps: hand-rolled JSON-RPC over node:http (matches the T1 stdio
// wrapper's dep-free discipline; cloudflared quick tunnels are JSON-only / no
// SSE anyway, so the SDK's streaming machinery buys nothing here).

import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { timingSafeEqual, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';

const SELF = fileURLToPath(import.meta.url);
const HOOK_DIR = dirname(SELF);                       // .../.claude/hooks/gptbridge
const GPTBRIDGE_SH = join(HOOK_DIR, 'gptbridge.sh');
const CLAUDE_DIR = resolve(HOOK_DIR, '..', '..');     // .../.claude

const TOKEN = process.env.GPTBRIDGE_TOKEN || '';
const PORT = Number(process.env.GPTBRIDGE_PORT || 8873) || 8873;
const SERVER_INFO = { name: 'chatgpt-consult-relay', version: '1.0.0' };
const DEFAULT_PROTOCOL = '2025-06-18';
const MAX_BODY = 256 * 1024;                          // JSON-RPC body cap (bytes)

function readConfig() {
  const p = (process.env.CLAUDE_PROJECT_DIR
    ? join(process.env.CLAUDE_PROJECT_DIR, '.claude', 'agent', 'config.json')
    : join(CLAUDE_DIR, 'agent', 'config.json'));
  try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return {}; }
}
function cfgNum(cfg, path, dflt) {
  let o = cfg;
  for (const k of path) { o = (o && typeof o === 'object') ? o[k] : undefined; }
  const n = Number(o);
  return Number.isFinite(n) && n > 0 ? n : dflt;
}
const CFG = readConfig();
const SYNC_WAIT_MS = 1000 * cfgNum(CFG, ['gptbridge', 'relay', 'sync_wait_s'], 20);
const MAX_CONSULT_BYTES = 1024 * cfgNum(CFG, ['gptbridge', 'relay', 'max_consult_kb'], 16);

const log = (...a) => { try { process.stderr.write('[relay] ' + a.join(' ') + '\n'); } catch {} };

// constant-time string compare (avoids a token timing oracle on the path/bearer)
function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) {
    // still burn a compare to keep timing ~flat, then fail
    try { timingSafeEqual(ba, ba); } catch {}
    return false;
  }
  try { return timingSafeEqual(ba, bb); } catch { return false; }
}

// --- gptbridge.sh bridge (the ONLY side-effecting surface) --------------------
function sh(args) {
  return new Promise((res) => {
    execFile('bash', [GPTBRIDGE_SH, ...args], { timeout: 30000, maxBuffer: 4 * 1024 * 1024 },
      (err, stdout) => res({ err, out: (stdout || '').toString() }));
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ingest(question, context) {
  const { out } = await sh(['ingest', '--question', question, '--context', context || '']);
  try { return JSON.parse(out.trim().split('\n').pop()); } catch { return { consult_id: '', status: 'error' }; }
}
async function replyGet(cid) {
  const { err, out } = await sh(['reply-get', cid]);
  if (err) return null;                     // exit 1 → nothing yet
  const t = out.replace(/\n$/, '');
  return t.length ? t : null;
}
async function deliver() {
  const { out } = await sh(['deliver']);
  try { return JSON.parse(out.trim().split('\n').pop()); } catch { return []; }
}

// --- tool handlers ------------------------------------------------------------
async function handleConsult(args) {
  const question = args && typeof args.question === 'string' ? args.question : '';
  const context = args && typeof args.context === 'string' ? args.context : '';
  if (!question.trim()) return { isError: true, text: 'question is required (non-empty string).' };
  if (Buffer.byteLength(question + context, 'utf8') > MAX_CONSULT_BYTES) {
    return { isError: true, text: `consult too large (max ${Math.round(MAX_CONSULT_BYTES / 1024)} KiB).` };
  }
  const r = await ingest(question, context);
  const cid = r.consult_id || '';
  switch (r.status) {
    case 'disabled': return { isError: true, text: 'The consult relay is disabled on the Claude side.' };
    case 'denied':   return { isError: true, text: 'This bridge has been denied by the owner. No consult was queued.' };
    case 'rate_limited': return { isError: true, text: 'Rate limit reached — try again later.' };
    case 'too_large':   return { isError: true, text: 'consult too large.' };
    case 'empty':       return { isError: true, text: 'question is required.' };
    case 'quarantined':
      return { isError: false, text: `Your consult was received but HELD for the owner's review by the content guard (consult_id ${cid}). If the owner clears it and replies, call check_relay later.` };
    case 'error':
      return { isError: true, text: 'The relay could not enqueue the consult.' };
    default: break; // queued | duplicate → wait for a reply
  }
  // sync-wait for an owner-approved reply
  const deadline = Date.now() + SYNC_WAIT_MS;
  while (Date.now() < deadline) {
    const reply = await replyGet(cid);
    if (reply) return { isError: false, text: reply };
    await sleep(1000);
  }
  return { isError: false, text: `Queued for the owner's Claude Code session (consult_id ${cid}). No reply within the sync window — call check_relay later to collect it once the owner approves an answer.` };
}

async function handleCheckRelay() {
  const items = await deliver();
  if (!Array.isArray(items) || !items.length) {
    return { isError: false, text: 'Nothing pending from the Claude Code session right now.' };
  }
  const lines = [];
  for (const it of items) {
    if (it.type === 'reply') {
      lines.push(`REPLY to your consult ${it.consult_id}:\n${it.text}`);
    } else if (it.type === 'question') {
      lines.push(`QUESTION from Claude (${it.id}) — the owner's Claude Code session is asking you:\n${it.text}\n(Answer in ChatGPT; to send it back the owner calls consult_claude or relays it manually.)`);
    }
  }
  return { isError: false, text: lines.join('\n\n---\n\n') };
}

const TOOLS = [
  {
    name: 'consult_claude',
    description:
      "Ask the owner's live Claude Code session a question and get its answer. " +
      'The question is delivered to the owner as UNTRUSTED data they review and answer ' +
      'in their session; there is no file/command/tool access here — this is pure ' +
      'message-passing. Waits briefly for an owner-approved reply; if none arrives in ' +
      'time it returns a consult_id — call check_relay later to collect the reply.',
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: 'The question for the Claude Code session.' },
        context: { type: 'string', description: 'Optional extra context (treated as data).' },
      },
      required: ['question'],
      additionalProperties: false,
    },
  },
  {
    name: 'check_relay',
    description:
      'Pull any pending items from the Claude Code session: owner-approved replies to ' +
      'your earlier consult_claude calls, and questions the owner\'s Claude session wants ' +
      'to ask you. Each item is delivered once. Call this when the owner says to "check the relay".',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
];

// --- JSON-RPC dispatch --------------------------------------------------------
async function dispatch(msg) {
  const { id, method, params } = msg;
  const isRequest = id !== undefined && id !== null;
  switch (method) {
    case 'initialize':
      return { id, result: { protocolVersion: (params && params.protocolVersion) || DEFAULT_PROTOCOL, capabilities: { tools: {} }, serverInfo: SERVER_INFO } };
    case 'notifications/initialized':
    case 'initialized':
      return null; // notification
    case 'ping':
      return isRequest ? { id, result: {} } : null;
    case 'tools/list':
      return { id, result: { tools: TOOLS } };
    case 'tools/call': {
      const name = params && params.name;
      const args = (params && params.arguments) || {};
      let r;
      if (name === 'consult_claude') r = await handleConsult(args);
      else if (name === 'check_relay') r = await handleCheckRelay();
      else return { id, error: { code: -32602, message: `unknown tool: ${name}` } };
      return { id, result: { content: [{ type: 'text', text: r.text }], isError: !!r.isError } };
    }
    default:
      return isRequest ? { id, error: { code: -32601, message: `method not found: ${method}` } } : null;
  }
}

// --- HTTP (Streamable HTTP transport, JSON-response mode) ---------------------
function authorized(req) {
  // capability-URL: POST /mcp/<token>
  const url = req.url || '';
  const m = url.match(/^\/mcp\/([^/?#]+)/);
  if (m && TOKEN && safeEqual(decodeURIComponent(m[1]), TOKEN)) return true;
  // optional Authorization: Bearer <token> (Agents-SDK callers)
  const auth = req.headers['authorization'] || '';
  const bm = auth.match(/^Bearer\s+(.+)$/i);
  if (bm && TOKEN && safeEqual(bm[1].trim(), TOKEN)) return true;
  return false;
}

const server = createServer((req, res) => {
  const send = (code, obj, extra) => {
    const body = typeof obj === 'string' ? obj : JSON.stringify(obj);
    res.writeHead(code, { 'Content-Type': typeof obj === 'string' ? 'text/plain' : 'application/json', ...(extra || {}) });
    res.end(body);
  };
  // healthz (loopback supervisor probe) — no token, no data.
  if (req.method === 'GET' && (req.url === '/healthz' || req.url === '/mcp/healthz')) return send(200, 'ok');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  if (req.method !== 'POST') return send(404, 'not found');
  if (!authorized(req)) { log('rejected: bad/missing token', req.url); return send(404, 'not found'); }

  let body = '', tooBig = false;
  req.on('data', (c) => { body += c; if (body.length > MAX_BODY) { tooBig = true; req.destroy(); } });
  req.on('end', async () => {
    if (tooBig) return send(413, { jsonrpc: '2.0', id: null, error: { code: -32600, message: 'request too large' } });
    let msg;
    try { msg = JSON.parse(body); } catch { return send(400, { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
    // Streamable HTTP allows a batch array; handle both.
    const sid = req.headers['mcp-session-id'] || randomUUID();
    try {
      if (Array.isArray(msg)) {
        const out = [];
        for (const m of msg) { const r = await dispatch(m); if (r) out.push({ jsonrpc: '2.0', ...r }); }
        return send(200, out.length ? out : { jsonrpc: '2.0', id: null, result: {} }, { 'Mcp-Session-Id': sid });
      }
      const r = await dispatch(msg);
      if (!r) { res.writeHead(202, { 'Mcp-Session-Id': sid }); return res.end(); } // notification → no body
      return send(200, { jsonrpc: '2.0', ...r }, { 'Mcp-Session-Id': sid });
    } catch (e) {
      log('dispatch error', e && e.message);
      return send(200, { jsonrpc: '2.0', id: (msg && msg.id) ?? null, error: { code: -32603, message: 'internal error' } });
    }
  });
});

server.on('error', (e) => { log('server error:', e && e.message); process.exit(1); });
server.listen(PORT, '127.0.0.1', () => log(`listening on 127.0.0.1:${PORT} (token ${TOKEN ? 'set' : 'MISSING'})`));

for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { try { server.close(); } catch {} process.exit(0); });
