(() => {
  "use strict";
  const positions = new WeakMap();
  const watched = new WeakSet();
  let lastState = null;
  let lastSent = 0;
  let dead = false;

  function send(playing, force = false) {
    if (dead) return;
    const now = Date.now();
    if (!force && playing === lastState && now - lastSent < 5000) return;
    lastState = playing;
    lastSent = now;
    try {
      chrome.runtime
        .sendMessage({ type: "daybook-video", playing })
        .catch(() => {
          dead = true;
        });
    } catch {
      dead = true;
    }
  }

  function sample() {
    let playing = false;
    // Only media playback properties are inspected. No titles, text, URLs,
    // screenshots, network requests, audio samples, or page content are copied.
    for (const video of document.querySelectorAll("video")) {
      if (!watched.has(video)) {
        watched.add(video);
        for (const event of ["pause", "ended", "emptied", "waiting", "stalled"])
          video.addEventListener(event, () => sample(), { passive: true });
        video.addEventListener(
          "timeupdate",
          () => {
            if (Date.now() - lastSent >= 5000) sample();
          },
          { passive: true },
        );
      }
      const observation = DaybookPlayback.observe(
        video,
        positions.get(video),
        Date.now(),
      );
      if (observation.playing) playing = true;
      positions.set(video, observation);
    }
    send(playing);
  }
  window.addEventListener("pagehide", () => send(false, true), {
    passive: true,
  });
  sample();
  setInterval(sample, 1000);
})();
