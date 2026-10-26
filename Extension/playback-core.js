(function (root) {
  "use strict";
  function advancing(video, oldTime) {
    return (
      !!video &&
      !video.paused &&
      !video.ended &&
      !video.seeking &&
      video.readyState >= 2 &&
      video.videoWidth > 0 &&
      video.videoHeight > 0 &&
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
      video.videoWidth > 0 &&
      video.videoHeight > 0;
    return {
      time: video.currentTime,
      lastAdvance,
      playing: eligible && now - lastAdvance <= 1500,
    };
  }
  const api = { advancing, observe, host, anyPlaying };
  root.DaybookPlayback = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
