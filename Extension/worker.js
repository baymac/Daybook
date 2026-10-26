"use strict";
importScripts("playback-core.js");
const tabs = new Map();
const epoch = crypto.randomUUID();
let port = null;
let lastNativeError = "Not connected yet";

function nativePort() {
  if (port) return port;
  port = chrome.runtime.connectNative("local.daybook.video");
  port.onMessage.addListener((reply) => {
    lastNativeError = reply.appRunning
      ? "Local bridge connected"
      : "Open Daybook to receive playback";
    chrome.storage.local.set({ bridgeStatus: lastNativeError });
  });
  port.onDisconnect.addListener(() => {
    lastNativeError =
      chrome.runtime.lastError?.message || "Local bridge disconnected";
    chrome.storage.local.set({ bridgeStatus: lastNativeError });
    port = null;
  });
  return port;
}

async function signAndSend(packet) {
  const settings = await chrome.storage.local.get(["pairingCode", "enabled"]);
  if (!settings.enabled || !/^[0-9a-f]{64}$/i.test(settings.pairingCode || ""))
    return;
  const bytes = Uint8Array.from(settings.pairingCode.match(/../g), (h) =>
    parseInt(h, 16),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    bytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const payload = new TextEncoder().encode(JSON.stringify(packet));
  const mac = Array.from(
    new Uint8Array(await crypto.subtle.sign("HMAC", key, payload)),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  let binary = "";
  for (const byte of payload) binary += String.fromCharCode(byte);
  nativePort().postMessage({ payload: btoa(binary), mac });
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (
    sender.id !== chrome.runtime.id ||
    message?.type !== "daybook-video" ||
    typeof message.playing !== "boolean" ||
    !Number.isInteger(sender.tab?.id) ||
    !Number.isInteger(sender.frameId)
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
  state.frames.set(sender.frameId, { playing: message.playing, at: now });
  for (const [id, frame] of state.frames)
    if (now - frame.at > 15000) state.frames.delete(id);
  const playing = DaybookPlayback.anyPlaying([...state.frames.values()], now);
  tabs.set(sender.tab.id, state);
  const previous = state.playing;
  state.playing = playing;
  if (
    (playing && (previous !== true || now - state.sent >= 5000)) ||
    (previous === true && !playing)
  ) {
    state.sent = now;
    signAndSend({
      version: 1,
      session: epoch + ":" + sender.tab.id,
      domain,
      playing,
      sentAt: now / 1000,
    }).catch((error) => {
      chrome.storage.local.set({
        bridgeStatus: String(error.message || error),
      });
    });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  const state = tabs.get(tabId);
  if (state?.playing)
    signAndSend({
      version: 1,
      session: epoch + ":" + tabId,
      domain: state.domain,
      playing: false,
      sentAt: Date.now() / 1000,
    }).catch(() => {});
  tabs.delete(tabId);
});
chrome.action.onClicked.addListener(() => chrome.runtime.openOptionsPage());
