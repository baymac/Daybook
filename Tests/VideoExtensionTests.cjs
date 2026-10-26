const test = require("node:test");
const assert = require("node:assert/strict");
const {
  advancing,
  observe,
  host,
  anyPlaying,
  rect,
  clip,
  regions,
  screenRegions,
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
test("Playback progress detection is independent of visibility and sound", () => {
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
  const tab = {
    id: 7,
    windowId: 3,
    active: true,
    audible: true,
    mutedInfo: { muted: false },
  };
  const window = { left: 0, top: 0, width: 1200, height: 900, state: "normal" };
  let connections = 0;
  const messages = [];
  const settings = { pairingCode: "a1".repeat(32), enabled };
  const port = {
    onMessage: {
      addListener(f) {
        queueMicrotask(() =>
          f({ kind: "ready", browserPID: 123, appRunning: true }),
        );
      },
    },
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
    setTimeout,
    clearTimeout,
    queueMicrotask,
    crypto: {
      randomUUID: () => "test-epoch",
      getRandomValues: (a) => crypto.webcrypto.getRandomValues(a),
      subtle: crypto.webcrypto.subtle,
    },
    btoa: (s) => Buffer.from(s, "binary").toString("base64"),
    DaybookPlayback: { host, anyPlaying, rect, clip, regions, screenRegions },
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
      windows: {
        async get() {
          return window;
        },
        onBoundsChanged: { addListener() {} },
      },
      tabs: {
        async get() {
          return tab;
        },
        onActivated: { addListener() {} },
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
    tab,
    window,
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
  assert.deepEqual(Object.keys(message).sort(), [
    "ciphertext",
    "nonce",
    "version",
  ]);
  assert.equal(message.version, 2);
  const sealed = Buffer.from(message.ciphertext, "base64");
  const decipher = crypto.createDecipheriv(
    "aes-256-gcm",
    Buffer.from(pairingCode, "hex"),
    Buffer.from(message.nonce, "base64"),
  );
  decipher.setAAD(Buffer.from("local.daybook.playback.v2"));
  decipher.setAuthTag(sealed.subarray(-16));
  return JSON.parse(
    Buffer.concat([decipher.update(sealed.subarray(0, -16)), decipher.final()]),
  );
}
function media(playing = true, token = "top", overrides = {}) {
  return {
    type: "daybook-media",
    token,
    playing,
    audio: true,
    regions: playing ? [{ x: 100, y: 100, width: 600, height: 400 }] : [],
    links: [],
    width: 1200,
    height: 800,
    pictureInPicture: false,
    pipWidth: 0,
    pipHeight: 0,
    ...overrides,
  };
}
test("Worker authenticates geometry and domain without forwarding private page URLs", async () => {
  const h = workerHarness();
  h.receive(media(true), { ...h.sender, id: "outsider" });
  assert.equal(h.messages.length, 0);
  h.receive(media(true), h.sender);
  await settleUntil(() => h.messages.length === 1);
  const packet = decodePacket(h.messages[0], h.settings.pairingCode);
  assert.deepEqual(Object.keys(packet).sort(), [
    "context",
    "domain",
    "playing",
    "sentAt",
    "session",
    "version",
  ]);
  assert.equal(packet.version, 2);
  assert.equal(packet.domain, "youtube.com");
  assert.equal(packet.context.browserPID, 123);
  assert.equal(packet.context.audible, true);
  assert.deepEqual(packet.context.regions, [
    { x: 100, y: 200, width: 600, height: 400 },
  ]);
  assert.ok(!JSON.stringify(packet).includes("secret"));
  assert.ok(!JSON.stringify(h.messages[0]).includes("youtube.com"));
  h.removed(7);
  await settleUntil(() => h.messages.length === 2);
  assert.equal(
    decodePacket(h.messages[1], h.settings.pairingCode).playing,
    false,
  );
});
test("Background tabs and minimized windows have no visible regions; focus is irrelevant", async () => {
  for (const change of [
    { tab: { active: false } },
    { window: { state: "minimized" } },
  ]) {
    const h = workerHarness();
    Object.assign(h.tab, change.tab);
    Object.assign(h.window, change.window);
    h.receive(media(), h.sender);
    await settleUntil(() => h.messages.length === 1);
    const p = decodePacket(h.messages[0], h.settings.pairingCode);
    assert.deepEqual(p.context.regions, []);
    assert.equal(p.context.audible, true);
  }
  const h = workerHarness();
  h.window.focused = false;
  h.tab.mutedInfo.muted = true;
  h.receive(media(), h.sender);
  await settleUntil(() => h.messages.length === 1);
  const p = decodePacket(h.messages[0], h.settings.pairingCode);
  assert.equal(p.context.regions.length, 1);
  assert.equal(p.context.audible, false);
});
test("Embedded frames project and clip through parents, including zoom", () => {
  const now = 1000;
  const top = {
    ...media(false),
    at: now,
    frameId: 0,
    links: [
      {
        child: "child",
        rect: { x: 100, y: -100, width: 600, height: 400 },
        clip: { x: 100, y: 0, width: 600, height: 300 },
      },
    ],
  };
  const child = {
    ...media(true, "child", {
      width: 600,
      height: 400,
      regions: [{ x: 0, y: 0, width: 600, height: 400 }],
    }),
    at: now,
    frameId: 1,
  };
  const frames = new Map([
    [0, top],
    [1, child],
  ]);
  assert.deepEqual(regions(frames, now), [
    { x: 100, y: 0, width: 600, height: 300 },
  ]);
  assert.deepEqual(regions(frames, now + 7000), []);
  top.links = [];
  assert.deepEqual(regions(frames, now), []);
  assert.deepEqual(
    screenRegions(
      [{ x: 10, y: 20, width: 300, height: 200 }],
      { width: 600, height: 400 },
      { left: -1200, top: 0, width: 1200, height: 900 },
    ),
    [{ x: -1180, y: 140, width: 600, height: 400 }],
  );
});
test("Frame aggregation, pause and reconnect preserve authenticated session identity", async () => {
  const h = workerHarness();
  h.receive(media(), h.sender);
  await settleUntil(() => h.messages.length === 1);
  h.receive(media(true, "child"), { ...h.sender, frameId: 1 });
  h.receive(media(false), h.sender);
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(
    decodePacket(h.messages.at(-1), h.settings.pairingCode).playing,
    true,
  );
  h.receive(media(false, "child"), { ...h.sender, frameId: 1 });
  await settleUntil(
    () =>
      decodePacket(h.messages.at(-1), h.settings.pairingCode).playing === false,
  );
  h.disconnect();
  h.receive(media(), h.sender);
  await settleUntil(
    () =>
      h.connections() === 2 &&
      decodePacket(h.messages.at(-1), h.settings.pairingCode).playing,
  );
  const disabled = workerHarness(false);
  disabled.receive(media(), disabled.sender);
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(disabled.messages.length, 0);
});
test("Audio elements can prove progress and stalled audio stops", () => {
  const audio = { ...moving, tagName: "AUDIO", videoWidth: 0, videoHeight: 0 };
  assert.equal(advancing(audio, 9), true);
  assert.equal(observe(audio, { time: 9, lastAdvance: 0 }, 1000).playing, true);
  assert.equal(
    observe(audio, { time: 10, lastAdvance: 1000 }, 3000).playing,
    false,
  );
});
test("Malformed geometry and old content messages are rejected", async () => {
  const h = workerHarness();
  h.receive({ type: "daybook-video", playing: true }, h.sender);
  h.receive(
    media(true, "top", { regions: [{ x: NaN, y: 0, width: 1, height: 2 }] }),
    h.sender,
  );
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(h.messages.length, 0);
});
