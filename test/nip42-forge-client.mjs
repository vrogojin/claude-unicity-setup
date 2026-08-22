#!/usr/bin/env node
// nip42-forge-client.mjs — adversarial helper for the NIP-42 self-test. It connects to the relay
// stub, waits for the AUTH challenge, then answers with a FORGED kind-22242 event (valid shape,
// tampered signature) and issues a REQ. If the relay's AUTH verification is real, the forged AUTH
// is rejected and the REQ stays gated → 0 events. Prints {authForged, gated, events} as JSON.
//
// Usage: node nip42-forge-client.mjs <ws-url> <dtag>
import * as nostr from '@unicitylabs/nostr-js-sdk';

const url = process.argv[2];
const dtag = process.argv[3];
const km = nostr.NostrKeyManager.generate();

const result = { authForged: false, gated: false, events: 0, okAccepted: null };
const ws = new WebSocket(url);
let reqSent = false;

ws.onmessage = (e) => {
  let a;
  try { a = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString()); } catch { return; }
  if (a[0] === 'AUTH' && typeof a[1] === 'string' && !result.authForged) {
    // Build a correctly-shaped AUTH event, then TAMPER the signature so verify() must fail.
    const ev = nostr.Event.create(km, {
      kind: 22242, created_at: Math.floor(Date.now() / 1000),
      tags: [['relay', url], ['challenge', a[1]]], content: '',
    }).toJSON();
    const sig = ev.sig;
    ev.sig = (sig[0] === 'a' ? 'b' : 'a') + sig.slice(1); // flip first nibble → invalid signature
    result.authForged = true;
    try { ws.send(JSON.stringify(['AUTH', ev])); } catch {}
    // Issue a REQ after a beat — a real relay leaves it gated because our AUTH was invalid.
    setTimeout(() => { reqSent = true; try { ws.send(JSON.stringify(['REQ', 'f0', { kinds: [30777], '#d': [dtag] }])); } catch {} }, 150);
    return;
  }
  if (a[0] === 'OK' && a[2] === false) result.okAccepted = false;   // relay rejected our forged AUTH
  if (a[0] === 'OK' && a[2] === true) result.okAccepted = true;
  if (a[0] === 'EVENT' && reqSent) result.events++;
  if (a[0] === 'CLOSED' && reqSent) result.gated = true;
};
ws.onerror = () => {};

setTimeout(() => { try { ws.close(); } catch {} process.stdout.write(JSON.stringify(result) + '\n'); process.exit(0); }, 2000);
