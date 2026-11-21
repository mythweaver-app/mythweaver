// A browser fingerprint for moderation (`Mythweaver.Moderation.Fingerprints`): a hash of canvas
// rendering, WebGL vendor and renderer, screen, time zone, languages and hardware hints. It survives
// clearing cookies, so a banned device that wipes its device cookie is still recognised. Sent as the
// LiveSocket's `fingerprint` connect param and with the login form.

function signal(read: () => unknown): string {
  try {
    const value = read();
    return value === undefined || value === null ? "" : String(value);
  } catch {
    return "";
  }
}

// Shapes only, no text: Chromium renders canvas text differently from one draw to the next (its
// anti-fingerprinting noise), so a text canvas gave the same browser a new hash on most page loads.
// Gradients, arcs and blending still differ between GPUs and drivers, and render the same each time.
function canvasSignal(): string {
  const canvas = document.createElement("canvas");
  canvas.width = 240;
  canvas.height = 60;
  const ctx = canvas.getContext("2d");
  if (!ctx) return "";
  const gradient = ctx.createLinearGradient(0, 0, 240, 60);
  gradient.addColorStop(0, "#f60");
  gradient.addColorStop(1, "#069");
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, 240, 60);
  ctx.globalCompositeOperation = "multiply";
  ctx.fillStyle = "rgba(102,204,0,0.7)";
  ctx.beginPath();
  ctx.arc(60, 30, 25, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = "rgba(255,0,255,0.5)";
  ctx.beginPath();
  ctx.arc(90, 30, 25, 0, Math.PI * 2);
  ctx.fill();
  return canvas.toDataURL();
}

function webglSignal(): string {
  const canvas = document.createElement("canvas");
  const gl = (canvas.getContext("webgl") ?? canvas.getContext("experimental-webgl")) as WebGLRenderingContext | null;
  if (!gl) return "";
  const debug = gl.getExtension("WEBGL_debug_renderer_info");
  if (debug) {
    return `${gl.getParameter(debug.UNMASKED_VENDOR_WEBGL)}|${gl.getParameter(debug.UNMASKED_RENDERER_WEBGL)}`;
  }
  return `${gl.getParameter(gl.VENDOR)}|${gl.getParameter(gl.RENDERER)}`;
}

function fnv1a(input: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

/**
 * 32 lowercase hex characters describing this browser on this device. Not unique: identical
 * devices (same model, OS and browser) can share it.
 */
export function computeFingerprint(): string {
  const nav = navigator as Navigator & { deviceMemory?: number };
  const joined = [
    signal(canvasSignal),
    signal(webglSignal),
    signal(() => `${screen.width}x${screen.height}x${screen.colorDepth}`),
    signal(() => window.devicePixelRatio),
    signal(() => Intl.DateTimeFormat().resolvedOptions().timeZone),
    signal(() => navigator.languages.join(",")),
    signal(() => navigator.hardwareConcurrency),
    signal(() => nav.deviceMemory),
    signal(() => navigator.platform),
    signal(() => navigator.maxTouchPoints),
  ].join("||");

  return [1, 2, 3, 4].map((seed) => fnv1a(`${seed}|${joined}`)).join("");
}
