// Boundary tests for the Push Relay: drive the worker's fetch handler as
// Cloudflare would (Request in, Response out) with APNs stubbed at the
// network edge — the outbound `fetch` call is replaced, nothing inside the
// worker is.

import { test, suite, before } from "node:test";
import assert from "node:assert/strict";

import { createRelay } from "../src/worker.js";

const nowMs = 1_753_305_600_000;

/** @type {{APNS_TEAM_ID: string, APNS_KEY_ID: string, APNS_TOPIC: string, APNS_KEY_P8: string}} */
let baseEnv;
/** @type {CryptoKey} */
let publicKey;

before(async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  publicKey = pair.publicKey;
  const der = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  const b64 = Buffer.from(der).toString("base64");
  baseEnv = {
    APNS_TEAM_ID: "TEAM123456",
    APNS_KEY_ID: "KEY1234567",
    APNS_TOPIC: "com.otreva.waycar",
    APNS_KEY_P8: `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`,
  };
});

const goodBody = {
  token: "ab".repeat(32),
  env: "production",
  envelope: '{"v":1,"kid":"5-CJJlt5uLU","n":"AAECAwQFBgcICQoL","ct":"opaque"}',
  collapse: "%5",
};

function pushRequest(body, { ip = "203.0.113.7", method = "POST", path = "/push", origin = "https://relay.example" } = {}) {
  return new Request(origin + path, {
    method,
    headers: { "content-type": "application/json", "cf-connecting-ip": ip },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
}

function apnsOk(id = "0BAD0C6E-0000-0000-0000-000000000000") {
  return new Response(null, { status: 200, headers: { "apns-id": id } });
}

/**
 * Stub the network edge: replace global fetch, record every outbound call,
 * and answer with `respond`.
 */
function stubApns(t, respond = () => apnsOk()) {
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, init) => {
    calls.push({ url: String(url), init, headers: new Headers(init.headers) });
    return respond(calls.length);
  });
  return calls;
}

function freezeTime(t, ms = nowMs) {
  return t.mock.method(Date, "now", () => ms);
}

suite("routing", () => {
  test("only POST is allowed on /push", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(undefined, { method: "GET" }), baseEnv);
    assert.equal(res.status, 405);
    assert.equal(res.headers.get("allow"), "POST");
    assert.equal(calls.length, 0);
  });

  test("unknown paths are 404", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody, { path: "/pushx" }), baseEnv);
    assert.equal(res.status, 404);
    assert.equal(calls.length, 0);
  });
});

suite("forwarding to APNs", () => {
  test("forwards the envelope verbatim with the APNs shape from ADR 0008", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);

    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { apnsId: "0BAD0C6E-0000-0000-0000-000000000000" });

    assert.equal(calls.length, 1);
    const call = calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${goodBody.token}`);
    assert.equal(call.init.method, "POST");
    assert.equal(call.headers.get("apns-topic"), "com.otreva.waycar");
    assert.equal(call.headers.get("apns-push-type"), "alert");
    assert.equal(call.headers.get("apns-priority"), "10");
    assert.equal(call.headers.get("apns-collapse-id"), "%5");
    assert.equal(call.headers.get("content-type"), "application/json");

    const payload = JSON.parse(call.init.body);
    assert.equal(payload.aps["mutable-content"], 1);
    assert.equal(payload.aps.alert.title, "Waycar");
    assert.equal(payload.aps.alert.body, "Agent update");
    assert.equal(payload.envelope, goodBody.envelope);
  });

  test("signs the APNs JWT with ES256 and Apple's claims", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    await relay.fetch(pushRequest(goodBody), baseEnv);

    const auth = calls[0].headers.get("authorization");
    assert.match(auth, /^bearer /);
    const [header64, claims64, signature64] = auth.slice("bearer ".length).split(".");
    assert.deepEqual(JSON.parse(Buffer.from(header64, "base64url").toString()), {
      alg: "ES256",
      kid: "KEY1234567",
    });
    assert.deepEqual(JSON.parse(Buffer.from(claims64, "base64url").toString()), {
      iss: "TEAM123456",
      iat: nowMs / 1000,
    });
    const verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      Buffer.from(signature64, "base64url"),
      Buffer.from(`${header64}.${claims64}`, "utf8"),
    );
    assert.equal(verified, true);
  });

  test("reuses the JWT across requests and re-signs after ~50 minutes", async (t) => {
    const calls = stubApns(t);
    const clock = freezeTime(t);
    const relay = createRelay();
    await relay.fetch(pushRequest(goodBody), baseEnv);
    clock.mock.mockImplementation(() => nowMs + 49 * 60_000);
    await relay.fetch(pushRequest(goodBody), baseEnv);
    clock.mock.mockImplementation(() => nowMs + 51 * 60_000);
    await relay.fetch(pushRequest(goodBody), baseEnv);

    const auths = calls.map((call) => call.headers.get("authorization"));
    assert.equal(auths[1], auths[0]);
    assert.notEqual(auths[2], auths[0]);
  });

  test("env=sandbox goes to the sandbox APNs host", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest({ ...goodBody, env: "sandbox" }), baseEnv);
    assert.equal(res.status, 200);
    assert.equal(calls[0].url, `https://api.sandbox.push.apple.com/3/device/${goodBody.token}`);
  });

  test("an omitted collapse key sends no apns-collapse-id", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const { collapse, ...withoutCollapse } = goodBody;
    await relay.fetch(pushRequest(withoutCollapse), baseEnv);
    assert.equal(calls[0].headers.get("apns-collapse-id"), null);
  });

  test("assumes nothing about its own origin", async (t) => {
    stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest(goodBody, { origin: "http://localhost:8787" }),
      baseEnv,
    );
    assert.equal(res.status, 200);
  });
});

suite("APNs status passthrough", () => {
  test("410 Unregistered is relayed with its reason and timestamp", async (t) => {
    stubApns(t, () =>
      new Response(JSON.stringify({ reason: "Unregistered", timestamp: 1753305600000 }), {
        status: 410,
      }),
    );
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 410);
    assert.deepEqual(await res.json(), { reason: "Unregistered", timestamp: 1753305600000 });
  });

  test("400 BadDeviceToken is relayed", async (t) => {
    stubApns(t, () => new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 }));
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { reason: "BadDeviceToken" });
  });

  test("a non-JSON APNs error body relays the status with a null reason", async (t) => {
    stubApns(t, () => new Response("gateway exploded", { status: 503 }));
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 503);
    assert.deepEqual(await res.json(), { reason: null });
  });

  test("an unreachable APNs is 502, not a crash", async (t) => {
    t.mock.method(globalThis, "fetch", async () => {
      throw new TypeError("network down");
    });
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 502);
    assert.deepEqual(await res.json(), { error: "apns_unreachable" });
  });
});

suite("request validation", () => {
  const cases = [
    ["non-JSON body", "not json {", "bad_json"],
    ["JSON scalar body", '"push"', "bad_json"],
    ["missing token", { ...goodBody, token: undefined }, "bad_token"],
    ["uppercase hex token", { ...goodBody, token: "AB".repeat(32) }, "bad_token"],
    ["non-hex token", { ...goodBody, token: "zz".repeat(32) }, "bad_token"],
    ["too-short token", { ...goodBody, token: "abcd" }, "bad_token"],
    ["missing env", { ...goodBody, env: undefined }, "bad_env"],
    ["unknown env", { ...goodBody, env: "prod" }, "bad_env"],
    ["missing envelope", { ...goodBody, envelope: undefined }, "bad_envelope"],
    ["empty envelope", { ...goodBody, envelope: "" }, "bad_envelope"],
    ["non-string envelope", { ...goodBody, envelope: { v: 1 } }, "bad_envelope"],
    ["non-string collapse", { ...goodBody, collapse: 5 }, "bad_collapse"],
    ["empty collapse", { ...goodBody, collapse: "" }, "bad_collapse"],
    ["collapse over 64 bytes", { ...goodBody, collapse: "x".repeat(65) }, "bad_collapse"],
  ];

  for (const [name, body, error] of cases) {
    test(`rejects ${name} without calling APNs`, async (t) => {
      const calls = stubApns(t);
      const relay = createRelay();
      const res = await relay.fetch(pushRequest(body), baseEnv);
      assert.equal(res.status, 400);
      assert.deepEqual(await res.json(), { error });
      assert.equal(calls.length, 0);
    });
  }

  test("a collapse key of exactly 64 bytes passes", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodBody, collapse: "x".repeat(64) }),
      baseEnv,
    );
    assert.equal(res.status, 200);
    assert.equal(calls[0].headers.get("apns-collapse-id"), "x".repeat(64));
  });

  test("missing APNs config is 500 relay_misconfigured", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const { APNS_KEY_P8, ...withoutKey } = baseEnv;
    const res = await relay.fetch(pushRequest(goodBody), withoutKey);
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "relay_misconfigured" });
    assert.equal(calls.length, 0);
  });

  test("a garbage .p8 is 500 relay_misconfigured", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), {
      ...baseEnv,
      APNS_KEY_P8: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n",
    });
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), { error: "relay_misconfigured" });
    assert.equal(calls.length, 0);
  });
});

suite("payload caps", () => {
  test("rejects when the APNs payload would exceed 4 KB, without calling APNs", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodBody, envelope: "x".repeat(4100) }),
      baseEnv,
    );
    assert.equal(res.status, 413);
    assert.deepEqual(await res.json(), { error: "payload_too_large" });
    assert.equal(calls.length, 0);
  });

  test("caps the request body itself", async (t) => {
    const calls = stubApns(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodBody, envelope: "x".repeat(9000) }),
      baseEnv,
    );
    assert.equal(res.status, 413);
    assert.deepEqual(await res.json(), { error: "request_too_large" });
    assert.equal(calls.length, 0);
  });
});

suite("rate limits", () => {
  test("limits per IP and answers 429 with retry-after", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const env = { ...baseEnv, RATE_LIMIT_IP_PER_MIN: "2" };

    assert.equal((await relay.fetch(pushRequest(goodBody), env)).status, 200);
    assert.equal((await relay.fetch(pushRequest(goodBody), env)).status, 200);
    const limited = await relay.fetch(pushRequest(goodBody), env);
    assert.equal(limited.status, 429);
    assert.deepEqual(await limited.json(), { error: "rate_limited" });
    assert.equal(limited.headers.get("retry-after"), "60");
    assert.equal(calls.length, 2);

    // Another IP is not affected.
    const other = await relay.fetch(pushRequest(goodBody, { ip: "198.51.100.9" }), env);
    assert.equal(other.status, 200);
  });

  test("limits per token across source IPs", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const env = { ...baseEnv, RATE_LIMIT_TOKEN_PER_MIN: "2" };

    for (let i = 0; i < 2; i += 1) {
      const res = await relay.fetch(pushRequest(goodBody, { ip: `203.0.113.${i}` }), env);
      assert.equal(res.status, 200);
    }
    const limited = await relay.fetch(pushRequest(goodBody, { ip: "203.0.113.99" }), env);
    assert.equal(limited.status, 429);
    assert.equal(calls.length, 2);

    // Another token from yet another IP still goes through.
    const other = await relay.fetch(
      pushRequest({ ...goodBody, token: "cd".repeat(32) }, { ip: "203.0.113.100" }),
      env,
    );
    assert.equal(other.status, 200);
  });
});

const nowSec = nowMs / 1000;
const activityEnvelope = '{"v":1,"kid":"Yw3NKWbEM2Y","n":"AAECAwQFBgcICQoL","ct":"opaque"}';
const goodActivity = {
  kind: "liveactivity",
  token: "ef".repeat(32),
  env: "production",
  event: "update",
  priority: 5,
  timestamp: nowSec,
  counts: { working: 2, blocked: 1, done: 0 },
  envelope: activityEnvelope,
};
const HOST_ID = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
const goodStart = {
  ...goodActivity,
  event: "start",
  priority: 10,
  counts: { working: 1, blocked: 0, done: 0, idle: 2 },
  stale_date: nowSec + 900,
  attributes_type: "AgentActivityAttributes",
  attributes: { hostID: HOST_ID },
  alert: { title: "Agents active", body: "Agent status is live on your Lock Screen." },
};

suite("live activity request validation", () => {
  const cases = [
    ["unknown kind", { ...goodActivity, kind: "foobar" }, "bad_kind"],
    ["kind on an alert body", { ...goodBody, kind: "alert" }, "bad_kind"],
    ["missing token", { ...goodActivity, token: undefined }, "bad_token"],
    ["uppercase hex token", { ...goodActivity, token: "EF".repeat(32) }, "bad_token"],
    ["missing env", { ...goodActivity, env: undefined }, "bad_env"],
    ["unknown env", { ...goodActivity, env: "prod" }, "bad_env"],
    ["missing event", { ...goodActivity, event: undefined }, "bad_event"],
    ["unknown event", { ...goodActivity, event: "begin" }, "bad_event"],
    ["alert on an update", { ...goodActivity, alert: { title: "a", body: "b" } }, "bad_alert"],
    ["attributes on an update", { ...goodActivity, attributes: { hostID: HOST_ID } }, "bad_attributes"],
    [
      "attributes_type on an end",
      { ...goodActivity, event: "end", attributes_type: "AgentActivityAttributes" },
      "bad_attributes_type",
    ],
    ["missing priority", { ...goodActivity, priority: undefined }, "bad_priority"],
    ["priority 4", { ...goodActivity, priority: 4 }, "bad_priority"],
    ["string priority", { ...goodActivity, priority: "10" }, "bad_priority"],
    [
      "priority 10 with zero blocked",
      { ...goodActivity, priority: 10, counts: { working: 1, blocked: 0, done: 0 } },
      "bad_priority",
    ],
    ["missing timestamp", { ...goodActivity, timestamp: undefined }, "bad_timestamp"],
    ["zero timestamp", { ...goodActivity, timestamp: 0 }, "bad_timestamp"],
    ["negative timestamp", { ...goodActivity, timestamp: -1 }, "bad_timestamp"],
    ["timestamp older than 86400s", { ...goodActivity, timestamp: nowSec - 86_401 }, "bad_timestamp"],
    ["timestamp more than 300s ahead", { ...goodActivity, timestamp: nowSec + 301 }, "bad_timestamp"],
    ["stale_date equal to timestamp", { ...goodActivity, stale_date: nowSec }, "bad_stale_date"],
    ["stale_date before timestamp", { ...goodActivity, stale_date: nowSec - 1 }, "bad_stale_date"],
    ["non-integer stale_date", { ...goodActivity, stale_date: nowSec + 0.5 }, "bad_stale_date"],
    ["dismissal_date on update", { ...goodActivity, dismissal_date: nowSec }, "bad_dismissal_date"],
    [
      "non-integer dismissal_date on end",
      { ...goodActivity, event: "end", dismissal_date: nowSec + 0.5 },
      "bad_dismissal_date",
    ],
    ["missing counts", { ...goodActivity, counts: undefined }, "bad_counts"],
    ["counts as array", { ...goodActivity, counts: [1, 2, 3] }, "bad_counts"],
    [
      "extra counts key",
      { ...goodActivity, counts: { working: 1, blocked: 1, done: 0, extra: 0 } },
      "bad_counts",
    ],
    ["missing counts key", { ...goodActivity, counts: { working: 1, blocked: 1 } }, "bad_counts"],
    [
      "counts value above 999",
      { ...goodActivity, counts: { working: 1000, blocked: 0, done: 0 } },
      "bad_counts",
    ],
    [
      "negative counts value",
      { ...goodActivity, counts: { working: -1, blocked: 0, done: 0 } },
      "bad_counts",
    ],
    [
      "negative idle count",
      { ...goodActivity, counts: { working: 1, blocked: 0, done: 0, idle: -1 } },
      "bad_counts",
    ],
    [
      "non-integer idle count",
      { ...goodActivity, counts: { working: 1, blocked: 0, done: 0, idle: 1.5 } },
      "bad_counts",
    ],
    [
      "idle count above 999",
      { ...goodActivity, counts: { working: 1, blocked: 0, done: 0, idle: 1000 } },
      "bad_counts",
    ],
    [
      "extra counts key alongside idle",
      { ...goodActivity, counts: { working: 1, blocked: 0, done: 0, idle: 0, extra: 0 } },
      "bad_counts",
    ],
    [
      "idle replacing a required counts key",
      { ...goodActivity, counts: { working: 1, blocked: 0, idle: 0 } },
      "bad_counts",
    ],
    ["missing envelope", { ...goodActivity, envelope: undefined }, "bad_envelope"],
    ["empty envelope", { ...goodActivity, envelope: "" }, "bad_envelope"],
    ["non-string envelope", { ...goodActivity, envelope: { v: 1 } }, "bad_envelope"],
    ["collapse present", { ...goodActivity, collapse: "x" }, "bad_collapse"],
  ];

  for (const [name, body, error] of cases) {
    test(`rejects ${name} without calling APNs`, async (t) => {
      const calls = stubApns(t);
      freezeTime(t);
      const relay = createRelay();
      const res = await relay.fetch(pushRequest(body), baseEnv);
      assert.equal(res.status, 400);
      assert.deepEqual(await res.json(), { error });
      assert.equal(calls.length, 0);
    });
  }

  test("accepts timestamp at the inclusive window edges", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    for (const timestamp of [nowSec - 86_400, nowSec + 300]) {
      const res = await relay.fetch(pushRequest({ ...goodActivity, timestamp }), baseEnv);
      assert.equal(res.status, 200);
    }
    assert.equal(calls.length, 2);
  });

  test("accepts priority 10 when blocked is at least 1", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest({ ...goodActivity, priority: 10 }), baseEnv);
    assert.equal(res.status, 200);
    assert.equal(calls[0].headers.get("apns-priority"), "10");
  });
});

suite("live activity forwarding to APNs", () => {
  test("sends liveactivity headers, derived topic, and no collapse id", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodActivity, stale_date: nowSec + 900 }),
      baseEnv,
    );

    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { apnsId: "0BAD0C6E-0000-0000-0000-000000000000" });
    assert.equal(calls.length, 1);
    const call = calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${goodActivity.token}`);
    assert.equal(call.init.method, "POST");
    assert.equal(call.headers.get("apns-push-type"), "liveactivity");
    assert.equal(call.headers.get("apns-topic"), "com.otreva.waycar.push-type.liveactivity");
    assert.equal(call.headers.get("apns-priority"), "5");
    assert.equal(call.headers.get("apns-collapse-id"), null);
    assert.equal(call.headers.get("content-type"), "application/json");
    assert.match(call.headers.get("authorization"), /^bearer /);
  });

  test("aps body is content-state only — no alert or mutable-content", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    await relay.fetch(
      pushRequest({ ...goodActivity, stale_date: nowSec + 900 }),
      baseEnv,
    );

    assert.equal(
      calls[0].init.body,
      `{"aps":{"timestamp":${nowSec},"event":"update","content-state":{"counts":{"working":2,"blocked":1,"done":0},"envelope":${activityEnvelope}},"stale-date":${nowSec + 900}}}`,
    );
    const payload = JSON.parse(calls[0].init.body);
    assert.deepEqual(Object.keys(payload), ["aps"]);
    assert.equal("alert" in payload.aps, false);
    assert.equal("mutable-content" in payload.aps, false);
    assert.deepEqual(payload.aps["content-state"].counts, goodActivity.counts);
    assert.deepEqual(payload.aps["content-state"].envelope, JSON.parse(activityEnvelope));
    assert.equal(payload.aps.timestamp, nowSec);
    assert.equal(payload.aps.event, "update");
    assert.equal(payload.aps["stale-date"], nowSec + 900);
    assert.equal("dismissal-date" in payload.aps, false);
  });

  test("forwards an optional idle count into content-state", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodActivity, counts: { idle: 3, done: 0, blocked: 1, working: 2 } }),
      baseEnv,
    );

    assert.equal(res.status, 200);
    assert.equal(
      calls[0].init.body,
      `{"aps":{"timestamp":${nowSec},"event":"update","content-state":{"counts":{"working":2,"blocked":1,"done":0,"idle":3},"envelope":${activityEnvelope}}}}`,
    );
  });

  test("accepts counts without idle and does not invent one", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodActivity), baseEnv);

    assert.equal(res.status, 200);
    const counts = JSON.parse(calls[0].init.body).aps["content-state"].counts;
    assert.deepEqual(counts, { working: 2, blocked: 1, done: 0 });
    assert.equal("idle" in counts, false);
  });

  test("omits optional dates unless the request carried them", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    await relay.fetch(pushRequest(goodActivity), baseEnv);
    const payload = JSON.parse(calls[0].init.body);
    assert.equal("stale-date" in payload.aps, false);
    assert.equal("dismissal-date" in payload.aps, false);
  });

  test("end events may include dismissal-date and never an alert field", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({
        ...goodActivity,
        event: "end",
        dismissal_date: nowSec,
      }),
      baseEnv,
    );
    assert.equal(res.status, 200);
    const payload = JSON.parse(calls[0].init.body);
    assert.equal(payload.aps.event, "end");
    assert.equal(payload.aps["dismissal-date"], nowSec);
    assert.equal("alert" in payload.aps, false);
    assert.equal("mutable-content" in payload.aps, false);
  });

  test("embeds the envelope without parsing or inspecting it", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const envelope = '{"v":1,"extra":true,"kid":"x"}';
    await relay.fetch(pushRequest({ ...goodActivity, envelope }), baseEnv);
    const payload = JSON.parse(calls[0].init.body);
    assert.deepEqual(payload.aps["content-state"].envelope, { v: 1, extra: true, kid: "x" });
  });

  test("env=sandbox goes to the sandbox APNs host", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest({ ...goodActivity, env: "sandbox" }), baseEnv);
    assert.equal(res.status, 200);
    assert.equal(calls[0].url, `https://api.sandbox.push.apple.com/3/device/${goodActivity.token}`);
  });

  test("reuses the same cached ES256 JWT as the alert path", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    await relay.fetch(pushRequest(goodBody), baseEnv);
    await relay.fetch(pushRequest(goodActivity), baseEnv);
    const auths = calls.map((call) => call.headers.get("authorization"));
    assert.equal(auths[1], auths[0]);
  });
});

suite("live activity APNs status and caps", () => {
  test("rejects when the APNs payload would exceed 4 KB, without calling APNs", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(
      pushRequest({ ...goodActivity, envelope: "x".repeat(4100) }),
      baseEnv,
    );
    assert.equal(res.status, 413);
    assert.deepEqual(await res.json(), { error: "payload_too_large" });
    assert.equal(calls.length, 0);
  });

  test("410 Unregistered is relayed with its reason and timestamp", async (t) => {
    stubApns(t, () =>
      new Response(JSON.stringify({ reason: "Unregistered", timestamp: 1753305600000 }), {
        status: 410,
      }),
    );
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodActivity), baseEnv);
    assert.equal(res.status, 410);
    assert.deepEqual(await res.json(), { reason: "Unregistered", timestamp: 1753305600000 });
  });
});

suite("live activity push-to-start", () => {
  const cases = [
    ["missing attributes_type", { ...goodStart, attributes_type: undefined }, "bad_attributes_type"],
    ["another attributes type", { ...goodStart, attributes_type: "OtherAttributes" }, "bad_attributes_type"],
    ["missing attributes", { ...goodStart, attributes: undefined }, "bad_attributes"],
    ["attributes as array", { ...goodStart, attributes: [HOST_ID] }, "bad_attributes"],
    ["extra attributes key", { ...goodStart, attributes: { hostID: HOST_ID, name: "mbp" } }, "bad_attributes"],
    ["non-UUID hostID", { ...goodStart, attributes: { hostID: "mbp.local" } }, "bad_attributes"],
    ["over-long hostID", { ...goodStart, attributes: { hostID: `${HOST_ID}-${"0".repeat(64)}` } }, "bad_attributes"],
    ["non-string hostID", { ...goodStart, attributes: { hostID: 7 } }, "bad_attributes"],
    ["missing alert", { ...goodStart, alert: undefined }, "bad_alert"],
    ["alert without body", { ...goodStart, alert: { title: "Agents active" } }, "bad_alert"],
    ["empty alert title", { ...goodStart, alert: { title: "", body: "b" } }, "bad_alert"],
    ["extra alert key", { ...goodStart, alert: { ...goodStart.alert, sound: "default" } }, "bad_alert"],
    ["alert text over 100 bytes", { ...goodStart, alert: { title: "é".repeat(51), body: "b" } }, "bad_alert"],
    ["dismissal_date on a start", { ...goodStart, dismissal_date: nowSec }, "bad_dismissal_date"],
  ];

  for (const [name, body, error] of cases) {
    test(`rejects ${name} without calling APNs`, async (t) => {
      const calls = stubApns(t);
      freezeTime(t);
      const relay = createRelay();
      const res = await relay.fetch(pushRequest(body), baseEnv);
      assert.equal(res.status, 400);
      assert.deepEqual(await res.json(), { error });
      assert.equal(calls.length, 0);
    });
  }

  test("forwards a start with attributes, the alert, and input-push-token", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodStart), baseEnv);

    assert.equal(res.status, 200);
    const call = calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${goodStart.token}`);
    assert.equal(call.headers.get("apns-push-type"), "liveactivity");
    assert.equal(call.headers.get("apns-topic"), "com.otreva.waycar.push-type.liveactivity");
    assert.equal(call.headers.get("apns-priority"), "10", "a start may use 10 with nothing blocked");
    assert.equal(
      call.init.body,
      `{"aps":{"timestamp":${nowSec},"event":"start","content-state":{"counts":{"working":1,"blocked":0,"done":0,"idle":2},"envelope":${activityEnvelope}},"stale-date":${nowSec + 900},"attributes-type":"AgentActivityAttributes","attributes":{"hostID":"${HOST_ID}"},"alert":{"title":"Agents active","body":"Agent status is live on your Lock Screen."},"input-push-token":1}}`,
    );
  });

  test("a 410 for a push-to-start token is relayed like any other", async (t) => {
    stubApns(t, () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }));
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodStart), baseEnv);
    assert.equal(res.status, 410);
    assert.deepEqual(await res.json(), { reason: "Unregistered" });
  });
});

suite("alert path compatibility", () => {
  test("alert requests without kind produce the pre-liveactivity APNs request bytes", async (t) => {
    const calls = stubApns(t);
    freezeTime(t);
    const relay = createRelay();
    const res = await relay.fetch(pushRequest(goodBody), baseEnv);
    assert.equal(res.status, 200);

    const call = calls[0];
    assert.equal(call.url, `https://api.push.apple.com/3/device/${goodBody.token}`);
    assert.equal(call.init.method, "POST");
    assert.equal(
      call.init.body,
      '{"aps":{"alert":{"title":"Waycar","body":"Agent update"},"mutable-content":1},"envelope":"{\\"v\\":1,\\"kid\\":\\"5-CJJlt5uLU\\",\\"n\\":\\"AAECAwQFBgcICQoL\\",\\"ct\\":\\"opaque\\"}"}',
    );

    const headers = { ...call.init.headers };
    assert.match(headers.authorization, /^bearer /);
    delete headers.authorization;
    assert.deepEqual(headers, {
      "apns-topic": "com.otreva.waycar",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
      "apns-collapse-id": "%5",
    });
  });
});

