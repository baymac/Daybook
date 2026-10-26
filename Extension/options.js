"use strict";
chrome.storage.local
  .get(["pairingCode", "enabled", "bridgeStatus"])
  .then((s) => {
    document.getElementById("code").value = s.pairingCode || "";
    document.getElementById("enabled").checked = s.enabled === true;
    document.getElementById("status").textContent =
      s.bridgeStatus || "Ready to pair";
  });
document.getElementById("save").addEventListener("click", async () => {
  const pairingCode = document
    .getElementById("code")
    .value.trim()
    .toLowerCase();
  const enabled = document.getElementById("enabled").checked;
  if (!/^[0-9a-f]{64}$/.test(pairingCode)) {
    document.getElementById("status").textContent =
      "Paste the 64-character code from Daybook Settings.";
    return;
  }
  await chrome.storage.local.set({ pairingCode, enabled });
  document.getElementById("status").textContent =
    "Saved. Keep Daybook running, start tracking, then reload your video tab.";
});
