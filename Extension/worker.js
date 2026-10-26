"use strict";
importScripts("playback-core.js");
const tabs = new Map();
const epoch = crypto.randomUUID();
const configured = (async () => {
  const settings = await chrome.storage.local.get([
    "pairingCode",
    "helperInstallID",
  ]);
  try {
    const response = await fetch(chrome.runtime.getURL("local-pairing.json"));
    if (!response.ok) return;
    const local = await response.json();
    if (
      /^[0-9a-f]{64}$/i.test(local.pairingCode || "") &&
      typeof local.installID === "string" &&
      local.installID !== settings.helperInstallID
    )
      await chrome.storage.local.set({
        pairingCode: local.pairingCode,
        enabled: true,
        helperInstallID: local.installID,
      });
  } catch {} // Manual pairing remains available for a source checkout.
})();
let connection = null;
function nativeConnection() {
  if (connection) return connection;
  const port = chrome.runtime.connectNative("local.daybook.video");
  let resolve, reject;
  const ready = new Promise((a, b) => {
    resolve = a;
    reject = b;
  });
  const timer = setTimeout(
    () => reject(new Error("Update Daybook and reload the extension")),
    3000,
  );
  const current = { port, ready };
  connection = current;
  port.onMessage.addListener((reply) => {
    if (
      reply.kind === "ready" &&
      Number.isInteger(reply.browserPID) &&
      reply.browserPID > 0
    ) {
      clearTimeout(timer);
      resolve(reply.browserPID);
    }
    chrome.storage.local.set({
      bridgeStatus: reply.appRunning
        ? "Local bridge connected"
        : "Open Daybook to receive playback",
    });
  });
  port.onDisconnect.addListener(() => {
    clearTimeout(timer);
    reject(
      new Error(
        chrome.runtime.lastError?.message || "Local bridge disconnected",
      ),
    );
    if (connection === current) connection = null;
  });
  // Always attach a handler even if settings have just been disabled.
  ready.catch(() => {});
  return current;
}
async function signAndSend(packet) {
  await configured;
  const settings = await chrome.storage.local.get(["pairingCode", "enabled"]);
  if (!settings.enabled || !/^[0-9a-f]{64}$/i.test(settings.pairingCode || ""))
    return;
  const native = nativeConnection();
  packet.context.browserPID = await native.ready;
  const bytes = Uint8Array.from(settings.pairingCode.match(/../g), (h) =>
    parseInt(h, 16),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    bytes,
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const payload = new TextEncoder().encode(JSON.stringify(packet));
  if (payload.length > 4096) return;
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(
    await crypto.subtle.encrypt(
      {
        name: "AES-GCM",
        iv: nonce,
        additionalData: new TextEncoder().encode("local.daybook.playback.v2"),
        tagLength: 128,
      },
      key,
      payload,
    ),
  );
  const base64 = (bytes) => {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
  };
  native.port.postMessage({
    version: 2,
    nonce: base64(nonce),
    ciphertext: base64(encrypted),
  });
}
function valid(message) {
  const token = (s) => typeof s === "string" && /^[a-zA-Z0-9-]{1,64}$/.test(s);
  return (
    message?.type === "daybook-media" &&
    token(message.token) &&
    typeof message.playing === "boolean" &&
    typeof message.audio === "boolean" &&
    Number.isFinite(message.width) &&
    message.width > 0 &&
    message.width < 32000 &&
    Number.isFinite(message.height) &&
    message.height > 0 &&
    message.height < 32000 &&
    Array.isArray(message.regions) &&
    message.regions.length <= 16 &&
    message.regions.every(DaybookPlayback.rect) &&
    Array.isArray(message.links) &&
    message.links.length <= 128 &&
    message.links.every(
      (l) =>
        token(l.child) &&
        DaybookPlayback.rect(l.rect) &&
        DaybookPlayback.rect(l.clip),
    ) &&
    typeof message.pictureInPicture === "boolean" &&
    [message.pipWidth, message.pipHeight].every(
      (n) => Number.isFinite(n) && n >= 0 && n < 32000,
    )
  );
}
async function publish(tabId, state, force = false) {
  if (tabs.get(tabId) !== state) return;
  const now = Date.now();
  const tab = await chrome.tabs.get(tabId);
  const win = await chrome.windows.get(tab.windowId);
  if (tabs.get(tabId) !== state) return;
  const fresh = [...state.frames.values()].filter((f) => now - f.at <= 6000);
  const playing = DaybookPlayback.anyPlaying(fresh, now);
  const top = fresh.find((f) => f.frameId === 0);
  const pip = fresh.find((f) => f.playing && f.pictureInPicture);
  const bounds = {
    x: win.left,
    y: win.top,
    width: win.width,
    height: win.height,
  };
  if (!DaybookPlayback.rect(bounds)) return;
  const regions =
    tab.active && win.state !== "minimized" && top
      ? DaybookPlayback.screenRegions(
          DaybookPlayback.regions(state.frames, now),
          top,
          win,
        )
      : [];
  const context = {
    browserPID: 0,
    window: bounds,
    regions,
    audible:
      !!tab.audible &&
      !tab.mutedInfo?.muted &&
      fresh.some((f) => f.playing && f.audio),
    pictureInPicture: !!pip,
    pipWidth: pip?.pipWidth || 0,
    pipHeight: pip?.pipHeight || 0,
  };
  const signature = JSON.stringify([playing, context]);
  if (!force && signature === state.signature && now - state.sent < 2000)
    return;
  state.signature = signature;
  state.sent = now;
  if (!playing && state.playing !== true) return;
  state.playing = playing;
  state.context = context;
  await signAndSend({
    version: 2,
    session: epoch + ":" + tabId,
    domain: state.domain,
    playing,
    sentAt: Date.now() / 1000,
    context,
  });
}
function schedule(tabId, state, force = false) {
  // Preserve packet order even when browser/native API replies take time.
  state.queue = (state.queue || Promise.resolve())
    .then(() => publish(tabId, state, force))
    .catch((error) =>
      chrome.storage.local.set({
        bridgeStatus: String(error.message || error),
      }),
    );
}
chrome.runtime.onMessage.addListener((message, sender) => {
  if (
    sender.id !== chrome.runtime.id ||
    !Number.isInteger(sender.tab?.id) ||
    !Number.isInteger(sender.frameId) ||
    !valid(message)
  )
    return;
  const domain = DaybookPlayback.host(sender.tab.url || "");
  const origin = sender.origin || sender.url || "";
  if (
    !domain ||
    (!origin.startsWith("http://") &&
      !origin.startsWith("https://") &&
      origin !== "null")
  )
    return;
  const now = Date.now();
  let state = tabs.get(sender.tab.id);
  if (!state || state.domain !== domain)
    state = { domain, frames: new Map(), playing: null, sent: 0 };
  if (state.frames.size >= 128 && !state.frames.has(sender.frameId)) return;
  state.frames.set(sender.frameId, {
    ...message,
    frameId: sender.frameId,
    at: now,
  });
  for (const [id, frame] of state.frames)
    if (now - frame.at > 6000) state.frames.delete(id);
  tabs.set(sender.tab.id, state);
  schedule(sender.tab.id, state);
});
chrome.tabs.onActivated.addListener((info) => {
  for (const [id, state] of tabs) schedule(id, state, true);
});
chrome.windows.onBoundsChanged.addListener(() => {
  for (const [id, state] of tabs) schedule(id, state, true);
});
chrome.tabs.onRemoved.addListener((tabId) => {
  const state = tabs.get(tabId);
  tabs.delete(tabId);
  if (state?.playing && state.context)
    signAndSend({
      version: 2,
      session: epoch + ":" + tabId,
      domain: state.domain,
      playing: false,
      sentAt: Date.now() / 1000,
      context: state.context,
    }).catch(() => {});
});
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
