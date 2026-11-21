import { decode } from "blurhash";
import type { Hook, HookInterface } from "phoenix_live_view";

/**
 * A blurred placeholder behind an image while it loads, from the attachment's stored blurhash
 * (`Mythweaver.Attachments.refresh_blurhash/1`).
 *
 * DOM contract: an `<img>` with `phx-hook="Blurhash"`, an `id` and `data-blurhash`. It needs a box
 * before it loads (`width`/`height`), or the placeholder has nothing to fill.
 *
 * The placeholder is the image's own `background-image`, cleared once it loads. A LiveView patch
 * drops client-set `style`, so `updated` paints again until then, from the cached data URL. An
 * invalid hash leaves the image alone.
 */
type State = {
  loaded: boolean;
  hash: string | null;
  placeholder: string | null;
  onLoad: () => void;
};

type Self = State & HookInterface;

const SIZE = 32;

function render(hash: string): string | null {
  try {
    const canvas = document.createElement("canvas");
    canvas.width = SIZE;
    canvas.height = SIZE;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    const image = ctx.createImageData(SIZE, SIZE);
    image.data.set(decode(hash, SIZE, SIZE));
    ctx.putImageData(image, 0, 0);
    return canvas.toDataURL();
  } catch {
    return null;
  }
}

function paint(self: Self) {
  const img = self.el as HTMLImageElement;
  if (self.loaded || (img.complete && img.naturalWidth !== 0)) return;
  const hash = img.dataset.blurhash ?? "";
  if (hash !== self.hash) {
    self.hash = hash;
    self.placeholder = hash ? render(hash) : null;
  }
  if (!self.placeholder) return;
  img.style.backgroundImage = `url(${self.placeholder})`;
  img.style.backgroundSize = "100% 100%";
}

export const Blurhash: Hook<State> = {
  mounted(this: Self) {
    this.loaded = false;
    this.hash = null;
    this.placeholder = null;
    this.onLoad = () => {
      this.loaded = true;
      this.el.style.removeProperty("background-image");
      this.el.style.removeProperty("background-size");
    };
    this.el.addEventListener("load", this.onLoad);
    paint(this);
  },

  updated(this: Self) {
    paint(this);
  },

  destroyed(this: Self) {
    this.el.removeEventListener("load", this.onLoad);
  },
};
