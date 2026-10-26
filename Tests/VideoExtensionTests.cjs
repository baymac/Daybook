const test = require("node:test");
const assert = require("node:assert/strict");
const {
  advancing,
  observe,
  host,
  anyPlaying,
} = require("../Extension/playback-core.js");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const crypto = require("node:crypto");
const moving = {
  paused: false,
  ended: false,
  seeking: false,
  readyState: 4,
  videoWidth: 1280,
  videoHeight: 720,
  currentTime: 10,
};
test("Only progressing video counts, including muted/background video", () => {
  assert.equal(advancing(moving, 9), true);
  assert.equal(advancing({ ...moving, muted: true }, 9), true);
  assert.equal(advancing(moving, 10), false);
  for (const change of [
    { paused: true },
    { ended: true },
    { seeking: true },
    { readyState: 1 },
    { videoWidth: 0 },
    { videoHeight: 0 },
  ])
    assert.equal(advancing({ ...moving, ...change }, 9), false);
});
test("Closely spaced progress/timer callbacks do not falsely pause video", () => {
  const a = observe(moving, { time: 9, lastAdvance: 0 }, 1000);
  assert.equal(a.playing, true);
  const b = observe(moving, a, 1001);
  assert.equal(b.playing, true);
  assert.equal(observe(moving, b, 3000).playing, false);
  assert.equal(observe({ ...moving, paused: true }, a, 1100).playing, false);
});
test("Embedded-frame aggregation keeps playing while any frame advances", () => {
  assert.equal(
    anyPlaying(
      [
        { playing: false, at: 1000 },
        { playing: true, at: 1000 },
      ],
      2000,
    ),
    true,
  );
  assert.equal(anyPlaying([{ playing: true, at: 0 }], 9000), false);
  assert.equal(anyPlaying([{ playing: false, at: 1000 }], 2000), false);
});
test("Only the top-level hostname is forwarded, with no path/title/query", () => {
  assert.equal(
    host("https://youtube.com/private/page?token=secret#fragment"),
    "youtube.com",
  );
  assert.equal(host("file:///private/file"), null);
  assert.equal(host("javascript:alert(1)"), null);
});

function workerHarness(enabled = true) {
  let receive, removed, disconnect;
  let connections = 0;
  const messages = [];
  const settings = { pairingCode: "a1".repeat(32), enabled };
  const port = {
    onMessage: { addListener() {} },
    onDisconnect: {
      addListener(f) {
        disconnect = f;
      },
    },
    postMessage(m) {
      messages.push(m);
    },
  };
  const context = vm.createContext({
    URL,
    TextEncoder,
    Date,
    console,
    crypto: { randomUUID: () => "test-epoch", subtle: crypto.webcrypto.subtle },
    btoa: (s) => Buffer.from(s, "binary").toString("base64"),
    DaybookPlayback: { host, anyPlaying },
    importScripts() {},
    chrome: {
      runtime: {
        id: "test-extension",
        connectNative(name) {
          assert.equal(name, "local.daybook.video");
          connections++;
          return port;
        },
        onMessage: {
          addListener(f) {
            receive = f;
          },
        },
      },
      storage: {
        local: {
          async get() {
            return settings;
          },
          async set(s) {
            Object.assign(settings, s);
          },
        },
      },
      tabs: {
        onRemoved: {
          addListener(f) {
            removed = f;
          },
        },
      },
      action: { onClicked: { addListener() {} } },
    },
  });
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, "../Extension/worker.js"), "utf8"),
    context,
  );
  const sender = {
    id: "test-extension",
    frameId: 0,
    origin: "https://player.example.net",
    tab: { id: 7, url: "https://youtube.com/watch?private-token=secret" },
  };
  return {
    messages,
    settings,
    sender,
    receive,
    removed,
    disconnect: () => disconnect(),
    connections: () => connections,
  };
}
async function settleUntil(check) {
  for (let i = 0; i < 100 && !check(); i++)
    await new Promise((resolve) => setTimeout(resolve, 5));
  assert.ok(check(), "asynchronous native packet was not sent");
}
function decodePacket(message, pairingCode) {
  const payload = Buffer.from(message.payload, "base64");
  const mac = crypto
    .createHmac("sha256", Buffer.from(pairingCode, "hex"))
    .update(payload)
    .digest("hex");
  assert.equal(message.mac, mac);
  return JSON.parse(payload);
}
test("Browser worker authenticates playback, rejects outsiders, and never forwards page URLs", async () => {
  const h = workerHarness();
  h.receive({ type: "daybook-video", playing: false }, h.sender);
  h.receive(
    { type: "daybook-video", playing: true },
    { ...h.sender, id: "other-extension" },
  );
  assert.equal(h.messages.length, 0);
  h.receive({ type: "daybook-video", playing: true }, h.sender);
  await settleUntil(() => h.messages.length === 1);
  const packet = decodePacket(h.messages[0], h.settings.pairingCode);
  assert.deepEqual(Object.keys(packet).sort(), [
    "domain",
    "playing",
    "sentAt",
    "session",
    "version",
  ]);
  assert.equal(packet.domain, "youtube.com");
  assert.equal(packet.playing, true);
  assert.equal(packet.session, "test-epoch:7");
  assert.ok(!JSON.stringify(packet).includes("secret"));
  h.removed(7);
  await settleUntil(() => h.messages.length === 2);
  assert.equal(
    decodePacket(h.messages[1], h.settings.pairingCode).playing,
    false,
  );
});
test("Pausing one frame does not stop another playing frame; disabled pairing sends nothing", async () => {
  const h = workerHarness();
  h.receive({ type: "daybook-video", playing: true }, h.sender);
  await settleUntil(() => h.messages.length === 1);
  h.receive(
    { type: "daybook-video", playing: true },
    { ...h.sender, frameId: 1 },
  );
  h.receive({ type: "daybook-video", playing: false }, h.sender);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(h.messages.length, 1);
  h.receive(
    { type: "daybook-video", playing: false },
    { ...h.sender, frameId: 1 },
  );
  await settleUntil(() => h.messages.length === 2);
  assert.equal(
    decodePacket(h.messages[1], h.settings.pairingCode).playing,
    false,
  );
  const disabled = workerHarness(false);
  disabled.receive({ type: "daybook-video", playing: true }, disabled.sender);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(disabled.messages.length, 0);
});

test("Browser reconnects after a native helper disconnect without re-pairing", async () => {
  const h = workerHarness();
  h.receive({ type: "daybook-video", playing: true }, h.sender);
  await settleUntil(() => h.messages.length === 1);
  assert.equal(h.connections(), 1);
  h.disconnect();
  h.receive({ type: "daybook-video", playing: false }, h.sender);
  await settleUntil(() => h.messages.length === 2);
  assert.equal(h.connections(), 2);
  assert.equal(
    decodePacket(h.messages[1], h.settings.pairingCode).playing,
    false,
  );
});
