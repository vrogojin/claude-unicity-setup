#!/usr/bin/env node
// nip42-relay-stub.mjs — a minimal, hermetic Nostr relay that ENFORCES NIP-42 AUTH, used to
// prove the sphere-helper raw WebSocket paths authenticate before the relay will serve them.
//
// It speaks just enough of RFC 6455 (server side) + NIP-01/NIP-42 to gate REQ/EVENT behind a
// verified kind-22242 AUTH event:
//   - On connect (mode=proactive) it sends ["AUTH", <challenge>].
//   - A pre-auth REQ  → ["CLOSED", subid, "auth-required: authentication required"]
//                       (+ an ["AUTH", challenge] in mode=reactive, to drive the CLOSED→AUTH path).
//   - A pre-auth EVENT→ ["OK", id, false, "auth-required: authentication required"] (+ reactive AUTH).
//   - ["AUTH", ev]    → verifies ev.kind==22242, the challenge tag == the one we issued, AND the
//                       schnorr signature (via the real SDK). Only then: ["OK", ev.id, true, ""].
//   - Post-auth REQ   → each stored event matching #d as ["EVENT", subid, ev] then ["EOSE", subid].
//   - Post-auth EVENT → stored + ["OK", id, true, ""].
//
// Usage: node nip42-relay-stub.mjs --store <events.json> [--mode proactive|reactive] [--events-log <f>]
// Prints "RELAY_URL=ws://127.0.0.1:<port>" on stdout, then serves until killed. All AUTH decisions
// are appended (one JSON line each) to --events-log so a test can assert what was gated/accepted.

import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { readFileSync, appendFileSync, existsSync } from 'node:fs';
import * as nostr from '@unicitylabs/nostr-js-sdk';

function parseArgs(argv) {
  const a = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) { const k = argv[i].slice(2); const n = argv[i + 1]; if (n && !n.startsWith('--')) { a[k] = n; i++; } else a[k] = true; }
    else a._.push(argv[i]);
  }
  return a;
}
const args = parseArgs(process.argv.slice(2));
const MODE = args.mode || 'proactive';
const LOG = args['events-log'] || null;
const store = (() => { try { return existsSync(args.store) ? JSON.parse(readFileSync(args.store, 'utf-8')) : []; } catch { return []; } })();
const logline = (o) => { if (LOG) { try { appendFileSync(LOG, JSON.stringify(o) + '\n'); } catch {} } };

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// --- RFC 6455 minimal server framing ---------------------------------------------------
function sendFrame(sock, str) {
  const payload = Buffer.from(str, 'utf-8');
  const len = payload.length;
  let header;
  if (len < 126) { header = Buffer.from([0x81, len]); }
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2); }
  try { sock.write(Buffer.concat([header, payload])); } catch {}
}

// Pull complete text frames out of a growing buffer. Returns {messages, rest, close}.
function drainFrames(buf) {
  const messages = [];
  let off = 0;
  let close = false;
  while (off + 2 <= buf.length) {
    const b0 = buf[off];
    const b1 = buf[off + 1];
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let p = off + 2;
    if (len === 126) { if (p + 2 > buf.length) break; len = buf.readUInt16BE(p); p += 2; }
    else if (len === 127) { if (p + 8 > buf.length) break; len = Number(buf.readBigUInt64BE(p)); p += 8; }
    let mask = null;
    if (masked) { if (p + 4 > buf.length) break; mask = buf.subarray(p, p + 4); p += 4; }
    if (p + len > buf.length) break; // incomplete payload
    const payload = Buffer.from(buf.subarray(p, p + len));
    if (mask) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
    off = p + len;
    if (opcode === 0x8) { close = true; break; }        // close
    if (opcode === 0x1 || opcode === 0x2) messages.push(payload.toString('utf-8'));
    // opcode 0x9 ping / 0xA pong — ignored for the test
  }
  return { messages, rest: buf.subarray(off), close };
}

const server = createServer();
server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  const accept = createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
  );

  const challenge = 'chal-' + createHash('sha1').update(String(Math.random()) + Date.now()).digest('hex').slice(0, 24);
  let authed = false;
  let buf = Buffer.alloc(0);

  if (MODE === 'proactive') sendFrame(socket, JSON.stringify(['AUTH', challenge]));

  const handle = (msg) => {
    let a;
    try { a = JSON.parse(msg); } catch { return; }
    if (!Array.isArray(a)) return;
    const verb = a[0];
    if (verb === 'AUTH') {
      const evJson = a[1];
      let ok = false;
      let id = (evJson && evJson.id) || '';
      try {
        const ev = nostr.Event.fromJSON(evJson);
        const tags = Array.isArray(evJson.tags) ? evJson.tags : [];
        const chalTag = tags.find((t) => Array.isArray(t) && t[0] === 'challenge');
        const relayTag = tags.find((t) => Array.isArray(t) && t[0] === 'relay');
        ok = Number(ev.kind) === 22242
          && chalTag && chalTag[1] === challenge         // must echo OUR challenge (anti-replay)
          && !!relayTag
          && ev.verify();                                // real schnorr signature check
      } catch { ok = false; }
      if (ok) authed = true;
      logline({ ev: 'auth', accepted: ok, id });
      sendFrame(socket, JSON.stringify(['OK', id, ok, ok ? '' : 'invalid: auth event rejected']));
      return;
    }
    if (verb === 'REQ') {
      const subid = a[1];
      const filter = a[2] || {};
      if (!authed) {
        logline({ ev: 'req-gated', subid });
        sendFrame(socket, JSON.stringify(['CLOSED', subid, 'auth-required: authentication required']));
        if (MODE === 'reactive') sendFrame(socket, JSON.stringify(['AUTH', challenge]));
        return;
      }
      const wantD = (filter['#d'] || []).map(String);
      let n = 0;
      for (const ev of store) {
        const tags = Array.isArray(ev.tags) ? ev.tags : [];
        const dtag = tags.find((t) => Array.isArray(t) && t[0] === 'd');
        if (wantD.length === 0 || (dtag && wantD.includes(String(dtag[1])))) {
          sendFrame(socket, JSON.stringify(['EVENT', subid, ev]));
          n++;
        }
      }
      logline({ ev: 'req-served', subid, count: n });
      sendFrame(socket, JSON.stringify(['EOSE', subid]));
      return;
    }
    if (verb === 'EVENT') {
      const ev = a[1];
      const id = (ev && ev.id) || '';
      if (!authed) {
        logline({ ev: 'event-gated', id });
        sendFrame(socket, JSON.stringify(['OK', id, false, 'auth-required: authentication required']));
        if (MODE === 'reactive') sendFrame(socket, JSON.stringify(['AUTH', challenge]));
        return;
      }
      store.push(ev);
      logline({ ev: 'event-accepted', id });
      sendFrame(socket, JSON.stringify(['OK', id, true, '']));
      return;
    }
  };

  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    const { messages, rest, close } = drainFrames(buf);
    buf = rest;
    for (const m of messages) handle(m);
    if (close) { try { socket.end(); } catch {} }
  });
  socket.on('error', () => {});
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  process.stdout.write(`RELAY_URL=ws://127.0.0.1:${port}\n`);
});
