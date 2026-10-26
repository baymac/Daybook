(function (root) {
  "use strict";
  function advancing(video, oldTime) {
    return (
      !!video &&
      !video.paused &&
      !video.ended &&
      !video.seeking &&
      video.readyState >= 2 &&
      (video.tagName === "AUDIO" ||
        (video.videoWidth > 0 && video.videoHeight > 0)) &&
      Number.isFinite(video.currentTime) &&
      Number.isFinite(oldTime) &&
      video.currentTime > oldTime + 0.02
    );
  }
  function host(raw) {
    try {
      const u = new URL(raw);
      return ["http:", "https:"].includes(u.protocol)
        ? u.hostname.toLowerCase()
        : null;
    } catch {
      return null;
    }
  }
  function anyPlaying(frames, now) {
    return frames.some(
      (f) => f.playing === true && now - f.at >= 0 && now - f.at <= 8000,
    );
  }
  function observe(video, previous, now) {
    const moved = advancing(video, previous?.time);
    const lastAdvance = moved ? now : (previous?.lastAdvance ?? -Infinity);
    const eligible =
      !video.paused &&
      !video.ended &&
      !video.seeking &&
      video.readyState >= 2 &&
      (video.tagName === "AUDIO" ||
        (video.videoWidth > 0 && video.videoHeight > 0));
    return {
      time: video.currentTime,
      lastAdvance,
      playing: eligible && now - lastAdvance <= 1500,
    };
  }
  function rect(r) {
    return (
      !!r &&
      [r.x, r.y, r.width, r.height].every(Number.isFinite) &&
      r.width > 0 &&
      r.height > 0 &&
      Math.abs(r.x) < 100000 &&
      Math.abs(r.y) < 100000 &&
      r.width < 32000 &&
      r.height < 32000
    );
  }
  function clip(a, b) {
    const x = Math.max(a.x, b.x),
      y = Math.max(a.y, b.y);
    const width = Math.min(a.x + a.width, b.x + b.width) - x,
      height = Math.min(a.y + a.height, b.y + b.height) - y;
    return width > 0 && height > 0 ? { x, y, width, height } : null;
  }
  // Resolve clipped rectangles through authenticated content-script frame links.
  function regions(frames, now) {
    const fresh = [...frames.values()].filter((f) => now - f.at <= 6000);
    const top = fresh.find((f) => f.frameId === 0);
    if (!top) return [];
    const result = [];
    for (const frame of fresh) {
      if (!frame.playing) continue;
      for (const region of frame.regions) {
        let r = region,
          current = frame;
        const seen = new Set();
        while (r && current.frameId !== 0 && seen.size < 12) {
          if (seen.has(current.token)) {
            r = null;
            break;
          }
          seen.add(current.token);
          const parent = fresh.find((f) =>
            f.links.some((l) => l.child === current.token),
          );
          const link = parent?.links.find((l) => l.child === current.token);
          if (!parent || !link) {
            r = null;
            break;
          }
          const sx = link.rect.width / current.width,
            sy = link.rect.height / current.height;
          r = clip(
            {
              x: link.rect.x + r.x * sx,
              y: link.rect.y + r.y * sy,
              width: r.width * sx,
              height: r.height * sy,
            },
            link.clip,
          );
          if (r)
            r = clip(r, {
              x: 0,
              y: 0,
              width: parent.width,
              height: parent.height,
            });
          current = parent;
        }
        if (r && current.frameId === 0 && result.length < 16) result.push(r);
      }
    }
    return result;
  }
  function screenRegions(local, top, window) {
    // innerWidth follows page zoom; outerWidth and Chrome window bounds use DIPs.
    const scale = window.width / top.width;
    const contentHeight = Math.min(window.height, top.height * scale);
    return local.map((r) => ({
      x: window.left + r.x * scale,
      y: window.top + window.height - contentHeight + r.y * scale,
      width: r.width * scale,
      height: r.height * scale,
    }));
  }
  const api = {
    advancing,
    observe,
    host,
    anyPlaying,
    rect,
    clip,
    regions,
    screenRegions,
  };
  root.DaybookPlayback = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
