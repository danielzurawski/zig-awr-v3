// Black-box WebSocket acceptance test against any AWR-V3 backend.
// Works against three implementations: the Zig firmware binary, the
// Node simulator, and the vendor Python `WebServer.py` (which is a
// strict subset — no SLAM extensions). Set INCLUDE_SLAM=1 to also
// assert mapping, get_map, slam_plan, and pose tracking; without it
// the test only exercises the common protocol subset that EVERY
// implementation must support.
//
// Uses the Node 22 built-in WebSocket so we don't need the `ws`
// package in the acceptance container.
//
// Failing assertions exit non-zero with a clear stderr message so the
// orchestrator can capture and report them.

import assert from "node:assert/strict";

const WS_URL = process.env.WS_URL ?? "ws://127.0.0.1:8889";
const AUTH = process.env.WS_AUTH ?? "admin:123456";
const TIMEOUT_MS = Number(process.env.WS_TIMEOUT_MS ?? 5000);
const INCLUDE_SLAM = process.env.INCLUDE_SLAM === "1";
const BACKEND_LABEL = process.env.BACKEND_LABEL ?? "unknown";
// SKIP_MOTION: drop motor + servo-driving commands from the common
// subset and force INCLUDE_SLAM off. Used by the in-situ runner when
// the robot is not on a stand so the test does not pulse the wheels.
const SKIP_MOTION = process.env.WS_SKIP_MOTION === "1";

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
  const slamTested = INCLUDE_SLAM && !SKIP_MOTION;
  const summary = {
    ok: false,
    backend_url: WS_URL,
    backend: BACKEND_LABEL,
    slam_tested: slamTested,
    skip_motion: SKIP_MOTION,
  };
  try {
    await authenticate(ws);

    // ---------- common protocol subset (every backend MUST support) ----------

    // 1. Telemetry envelope. The vendor Python returns 3 numbers and
    //    a 4th may be added by Zig (battery). We accept either >=3.
    const info = JSON.parse(await send(ws, "get_info"));
    assert.equal(info.title, "get_info");
    assert.ok(Array.isArray(info.data), "get_info data must be an array");
    assert.ok(info.data.length >= 3, `get_info data must have >=3 entries, got ${info.data.length}`);
    for (const v of info.data) assert.ok(Number.isFinite(Number.parseFloat(v)), `get_info value not numeric: ${v}`);
    summary.get_info_len = info.data.length;

    // 2. Movement and stop commands always ack. Skipped in --no-motion
    //    mode (in-situ when wheels are on the floor).
    if (!SKIP_MOTION) {
      for (const cmd of ["forward", "DS", "backward", "DS", "left", "TS", "right", "TS",
                         "rotate-left", "TS", "rotate-right", "TS",
                         "up", "UDstop", "down", "UDstop"]) {
        assert.equal(JSON.parse(await send(ws, cmd)).status, "ok", `cmd ${cmd}`);
      }
    }

    // 3. Speed setting
    assert.equal(JSON.parse(await send(ws, "wsB 30")).status, "ok");

    // 4. LED port switches
    for (const cmd of ["Switch_1_on", "Switch_2_on", "Switch_3_on",
                       "Switch_1_off", "Switch_2_off", "Switch_3_off"]) {
      assert.equal(JSON.parse(await send(ws, cmd)).status, "ok", `cmd ${cmd}`);
    }

    // 5. Function toggles (police is universal; the others are advisory but
    //    every backend must at minimum return status:ok for the OFF variants)
    for (const cmd of ["police", "policeOff",
                       "automaticOff", "trackLineOff", "keepDistanceOff", "stopCV"]) {
      assert.equal(JSON.parse(await send(ws, cmd)).status, "ok", `cmd ${cmd}`);
    }

    // 6. Servo calibration commands
    for (const cmd of ["SiLeft 0", "SiRight 0", "PWMMS 0", "PWMINIT", "PWMD"]) {
      assert.equal(JSON.parse(await send(ws, cmd)).status, "ok", `cmd ${cmd}`);
    }

    // 7. JSON payload (findColorSet)
    const colorReply = JSON.parse(await send(ws, JSON.stringify({ title: "findColorSet", data: [120, 200, 200] })));
    assert.equal(colorReply.status, "ok");

    // ---------- SLAM extensions (Zig firmware + Node simulator only) ----------
    if (slamTested) {
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
        `pose_x should advance forward: before=${before.data.x} after=${after.data.x}`);

      const plan = JSON.parse(await send(ws, "slam_plan 50 50"));
      assert.equal(plan.title, "slam_plan");
      assert.equal(typeof plan.data.found, "boolean");
      assert.equal(typeof plan.data.length, "number");

      const heading0 = after.data.theta;
      for (let i = 0; i < 4; i++) await send(ws, "rotate-left");
      const turned = JSON.parse(await send(ws, "get_map"));
      assert.notEqual(turned.data.theta, heading0, "rotate-left should change theta");

      assert.equal(JSON.parse(await send(ws, "mappingOff")).title, "mappingOff");
      const final = JSON.parse(await send(ws, "get_map"));
      assert.equal(final.data.mapping, false, "mappingOff should clear flag");

      summary.slam = {
        grid_size: after.data.size,
        pose_advance: after.data.x - before.data.x,
        plan_length: plan.data.length,
        coverage: after.data.coverage,
        frontiers: after.data.frontiers,
        theta_changed: turned.data.theta !== heading0,
      };
    }

    summary.ok = true;
    console.log(JSON.stringify(summary));
  } finally {
    // Safety net: zero the wheels and the camera tilt no matter how we
    // got here (clean exit, assertion failure, timeout). The SLAM section
    // intentionally streams `forward`/`rotate-left` without per-command
    // stops to exercise pose accumulation; if the test errored mid-stream
    // the PCA9685 would otherwise keep the last PWM duty cycle until the
    // *next* command — which is how the robot ends up with wheels still
    // spinning after an aborted run.
    try {
      if (ws.readyState === 1 /* OPEN */ && !SKIP_MOTION) {
        for (const safeStop of ["DS", "TS", "UDstop"]) {
          try { ws.send(safeStop); } catch {}
        }
        // Give the backend ~50 ms to flush motor PWM=0 over I2C before
        // we tear down the connection.
        await new Promise((r) => setTimeout(r, 50));
      }
    } catch {}
    try { ws.close(); } catch {}
  }
}

main().catch((err) => {
  console.error(`ws-protocol-test FAILED: ${err.message}`);
  if (err.stack) console.error(err.stack);
  process.exit(1);
});
