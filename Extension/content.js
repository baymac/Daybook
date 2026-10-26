(() => {
  "use strict";
  const positions = new WeakMap();
  const intersections = new WeakMap();
  const watched = new WeakSet();
  const children = new Map();
  const token = crypto.randomUUID();
  let lastSent = 0,
    dead = false;
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) intersections.set(entry.target, entry);
    },
    { threshold: [0, 0.1, 0.5, 1], trackVisibility: true, delay: 100 },
  );
  function localRect(element) {
    const entry = intersections.get(element);
    if (!entry?.isIntersecting || entry.isVisible === false) return null;
    if (
      element.checkVisibility &&
      !element.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
    )
      return null;
    const box = element.getBoundingClientRect();
    const r = DaybookPlayback.clip(
      { x: box.x, y: box.y, width: box.width, height: box.height },
      { x: 0, y: 0, width: innerWidth, height: innerHeight },
    );
    if (!r) return null;
    // Same-document overlays can obscure a player without hiding its window.
    let uncovered = 0;
    for (const fx of [0.2, 0.5, 0.8])
      for (const fy of [0.2, 0.5, 0.8]) {
        const hit = document.elementFromPoint(
          r.x + r.width * fx,
          r.y + r.height * fy,
        );
        if (hit === element || element.contains(hit)) uncovered++;
      }
    return uncovered > 0 ? r : null;
  }
  window.addEventListener("message", (event) => {
    if (
      event.data?.type !== "daybook-frame-token" ||
      !/^[a-zA-Z0-9-]{1,64}$/.test(event.data.token || "")
    )
      return;
    for (const frame of document.querySelectorAll("iframe,frame")) {
      if (frame.contentWindow === event.source && children.size < 128)
        children.set(event.data.token, { frame, at: Date.now() });
    }
  });
  function send(message) {
    if (dead) return;
    try {
      chrome.runtime.sendMessage(message).catch(() => {
        dead = true;
      });
    } catch {
      dead = true;
    }
  }
  function sample(force = false, stopped = false) {
    const now = Date.now();
    if (!force && now - lastSent < 1000) return;
    lastSent = now;
    let playing = false,
      audio = false,
      pictureInPicture = false,
      pipWidth = 0,
      pipHeight = 0;
    const regions = [];
    // Read media state and geometry only. Never copy titles, page text or full URLs.
    for (const media of document.querySelectorAll("video,audio")) {
      if (!watched.has(media)) {
        watched.add(media);
        observer.observe(media);
        media.addEventListener("timeupdate", () => sample(), { passive: true });
        if (media.tagName === "VIDEO" && media.requestVideoFrameCallback) {
          const frame = () => {
            if (dead) return;
            sample();
            media.requestVideoFrameCallback(frame);
          };
          media.requestVideoFrameCallback(frame);
        }
        for (const event of [
          "pause",
          "ended",
          "emptied",
          "waiting",
          "stalled",
          "volumechange",
          "enterpictureinpicture",
          "leavepictureinpicture",
        ])
          media.addEventListener(event, () => sample(true), { passive: true });
      }
      const state = DaybookPlayback.observe(media, positions.get(media), now);
      positions.set(media, state);
      if (!state.playing || stopped) continue;
      playing = true;
      if (!media.muted && media.volume > 0) audio = true;
      if (media === document.pictureInPictureElement) {
        pictureInPicture = true;
        pipWidth = pip?.width || 0;
        pipHeight = pip?.height || 0;
      }
      if (media.tagName === "VIDEO" && document.visibilityState === "visible") {
        const r = localRect(media);
        if (r && regions.length < 16) regions.push(r);
      }
    }
    const links = [];
    for (const [child, value] of children) {
      if (!value.frame.isConnected || now - value.at > 6000) {
        children.delete(child);
        continue;
      }
      const r = localRect(value.frame);
      if (r && links.length < 128) {
        const box = value.frame.getBoundingClientRect();
        const rect = {
          x: box.x + value.frame.clientLeft,
          y: box.y + value.frame.clientTop,
          width: value.frame.clientWidth,
          height: value.frame.clientHeight,
        };
        if (DaybookPlayback.rect(rect)) links.push({ child, rect, clip: r });
      }
      if (!watched.has(value.frame)) {
        watched.add(value.frame);
        observer.observe(value.frame);
      }
    }
    if (parent !== window)
      parent.postMessage({ type: "daybook-frame-token", token }, "*");
    send({
      type: "daybook-media",
      token,
      playing,
      audio,
      regions,
      links,
      width: innerWidth,
      height: innerHeight,
      pictureInPicture,
      pipWidth,
      pipHeight,
    });
  }
  let pip = null;
  document.addEventListener(
    "enterpictureinpicture",
    (event) => {
      pip = event.pictureInPictureWindow;
      sample(true);
    },
    true,
  );
  document.addEventListener(
    "leavepictureinpicture",
    () => {
      pip = null;
      sample(true);
    },
    true,
  );
  document.addEventListener("visibilitychange", () => sample(true));
  window.addEventListener("pagehide", () => sample(true, true), {
    passive: true,
  });
  sample();
  setInterval(sample, 1000);
})();
