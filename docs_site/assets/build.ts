// Builds the docs site's CSS, JS, fonts and logo into ../_site. `bun run build.ts` builds once,
// minified; `--watch` rebuilds unminified on change, and touches ../_site/.content-changed when
// ../../docs changes so the Tableau dev server (which watches only docs_site/) reloads the page.
import { watch } from "node:fs";
import { mkdir, copyFile, writeFile } from "node:fs/promises";
import { Features, bundle } from "lightningcss";

const WATCH = process.argv.includes("--watch");
const minify = !WATCH;
const OUT = "../_site";

const log = (msg: string) => console.log(`[docs assets ${new Date().toTimeString().slice(0, 8)}] ${msg}`);

async function buildCss() {
  // `customMedia` resolves the app's `@custom-media` names (../../assets/css/media.css).
  const { code } = bundle({
    filename: "css/site.css",
    minify,
    drafts: { customMedia: true },
    include: Features.CustomMediaQueries,
  });
  await mkdir(`${OUT}/css`, { recursive: true });
  await Bun.write(`${OUT}/css/site.css`, code);
}

async function buildJs() {
  const result = await Bun.build({ entrypoints: ["js/site.ts"], outdir: `${OUT}/js`, minify, target: "browser" });
  if (!result.success) throw new AggregateError(result.logs, "JS build failed");
}

async function copyStatic() {
  await mkdir(`${OUT}/fonts`, { recursive: true });
  await mkdir(`${OUT}/images`, { recursive: true });
  for (const font of ["Inter-VariableFont_opsz,wght.ttf", "Inter-Italic-VariableFont_opsz,wght.ttf"]) {
    await copyFile(`../../priv/static/fonts/${font}`, `${OUT}/fonts/${font}`);
  }
  await copyFile("../../priv/static/images/logo.svg", `${OUT}/images/logo.svg`);
}

async function run(step: string, fn: () => Promise<void>) {
  try {
    await fn();
    log(`built ${step}`);
  } catch (error) {
    console.error(error);
    if (!WATCH) process.exit(1);
  }
}

await run("css", buildCss);
await run("js", buildJs);
await run("fonts and logo", copyStatic);

if (WATCH) {
  for (const dir of ["css", "../../assets/css/tokens.css", "../../assets/css/media.css"]) {
    watch(dir, () => run("css", buildCss));
  }
  watch("js", () => run("js", buildJs));
  watch("../../docs", { recursive: true }, () =>
    run("content marker", () => writeFile(`${OUT}/.content-changed`, String(Date.now()))),
  );
  log("watching");
}
