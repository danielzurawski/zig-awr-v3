// Black-box WebSocket acceptance test against any AWR-V3 backend.
// Works against both the Zig firmware binary and the Node simulator —
// the only thing it requires is a listener at WS_URL that speaks the
// AWR-V3 protocol (auth, get_info, movement, mapping, get_map,
// slam_plan). Uses the Node 22 built-in WebSocket so we don't need
// the `ws` package in the acceptance container.
//
// Failing assertions exit non-zero with a clear stderr message so the
// orchestrator can capture and report them.

import assert from "node:assert/strict";

const WS_URL = process.env.WS_URL ?? "ws://127.0.0.1:8889";
const AUTH = process.env.WS_AUTH ?? "admin:123456";
const TIMEOUT_MS = Number(process.env.WS_TIMEOUT_MS ?? 5000);

if (typeof globalThis.WebSocket !== "function") {
  console.error("Node 22+ is required (built-in WebSocket missing).");
  process.exit(2);
}

function open() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      reject(new Error(`open() timed out after ${TIMEOUT_MS}ms (WS_URL=${WS_URL})`));
    }, TIMEOUT_MS);
    ws.addEventListener("open", () => { clearTimeout(timer); resolve(ws); }, { once: true });
    ws.addEventListener("error", (event) => {
      clearTimeout(timer);
      reject(new Error(`open() errored: ${event?.message ?? "unknown"}`));
    }, { once: true });
  });
}

function next(ws) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      ws.removeEventListener("message", onMsg);
      reject(new Error(`waited ${TIMEOUT_MS}ms for response`));
    }, TIMEOUT_MS);
    const onMsg = (event) => {
      clearTimeout(timer);
      ws.removeEventListener("message", onMsg);
      const data = typeof event.data === "string"
        ? event.data
        : new TextDecoder().decode(event.data);
      resolve(data);
    };
    ws.addEventListener("message", onMsg);
  });
}

async function send(ws, message) {
  ws.send(message);
  return next(ws);
}

async function authenticate(ws) {
  const accepted = await send(ws, AUTH);
  assert.match(accepted, /congratulation/, "auth banner mismatch");
}

async function main() {
  const ws = await open();
  try {
    await authenticate(ws);

    // 1. Telemetry envelope shape
    const info = JSON.parse(await send(ws, "get_info"));
    assert.equal(info.title, "get_info");
    assert.ok(Array.isArray(info.data) && info.data.length === 4, "get_info data must be 4-element array");
    for (const v of info.data) assert.ok(Number.isFinite(Number.parseFloat(v)), `get_info value not numeric: ${v}`);

    // 2. SLAM round-trip
    assert.equal(JSON.parse(await send(ws, "slam_reset")).status, "ok");
    const before = JSON.parse(await send(ws, "get_map"));
    assert.equal(before.title, "get_map", "get_map title");
    assert.ok(typeof before.data.grid === "string", "grid must be a string");
    assert.equal(before.data.grid.length, before.data.size * before.data.size, "grid size mismatch");
    assert.equal(before.data.mapping, false, "fresh state should not be mapping");

    assert.equal(JSON.parse(await send(ws, "mapping")).title, "mapping");
    for (let i = 0; i < 6; i++) await send(ws, "forward");
    const after = JSON.parse(await send(ws, "get_map"));
    assert.equal(after.title, "get_map");
    assert.equal(after.data.mapping, true, "mapping flag should be true after `mapping`");
    assert.ok(after.data.x >= before.data.x,
      `pose_x should advance forward (or stay clamped): before=${before.data.x} after=${after.data.x}`);

    // 3. Path planning envelope
    const plan = JSON.parse(await send(ws, "slam_plan 50 50"));
    assert.equal(plan.title, "slam_plan");
    assert.equal(typeof plan.data.found, "boolean");
    assert.equal(typeof plan.data.length, "number");

    // 4. Pose tracking on rotation
    const heading0 = after.data.theta;
    for (let i = 0; i < 4; i++) await send(ws, "rotate-left");
    const turned = JSON.parse(await send(ws, "get_map"));
    assert.notEqual(turned.data.theta, heading0, "rotate-left should change theta");

    // 5. Stop mapping cleanly
    assert.equal(JSON.parse(await send(ws, "mappingOff")).title, "mappingOff");
    const final = JSON.parse(await send(ws, "get_map"));
    assert.equal(final.data.mapping, false, "mappingOff should clear flag");

    // 6. Movement stop commands
    assert.equal(JSON.parse(await send(ws, "DS")).status, "ok");
    assert.equal(JSON.parse(await send(ws, "TS")).status, "ok");

    console.log(JSON.stringify({
      ok: true,
      backend_url: WS_URL,
      grid_size: after.data.size,
      pose_before: { x: before.data.x, y: before.data.y, theta: before.data.theta },
      pose_after_forward: { x: after.data.x, y: after.data.y, theta: after.data.theta },
      pose_after_rotate: { x: turned.data.x, y: turned.data.y, theta: turned.data.theta },
      plan_length: plan.data.length,
      coverage: after.data.coverage,
      frontiers: after.data.frontiers,
    }));
  } finally {
    try { ws.close(); } catch {}
  }
}

main().catch((err) => {
  console.error(`ws-protocol-test FAILED: ${err.message}`);
  if (err.stack) console.error(err.stack);
  process.exit(1);
});
