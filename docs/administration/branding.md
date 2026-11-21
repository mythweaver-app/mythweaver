---
title: Branding
order: 7
description: Renaming your installation and replacing its logo.
---

You can give your installation its own name and logo. Both are fixed when the app is built, not when it starts.

## To rename the installation

Set `MYTHWEAVER_NAME` before building. The name appears in the top bar, the browser tab title, the login and setup pages, the installable app's manifest, and test push notifications. A blank value counts as unset and keeps `Mythweaver`.

## To replace the logo

Set `MYTHWEAVER_LOGO_PATH` to an SVG file, either an absolute path or relative to the project root. The logo is drawn 1em square in the top bar. Use `currentColor` in the SVG so it follows the text color in light and dark themes.

> [!WARNING]
> A missing file or a file that isn't SVG fails the build.

## To apply a change

Both variables are read at build time, so set them for `mix compile` and `mix assets.deploy` (or the release build), then rebuild. With Docker, pass them as build arguments:

```bash
docker build -t mythweaver --build-arg MYTHWEAVER_NAME="Tale Forge" --build-arg MYTHWEAVER_LOGO_PATH=branding/logo.svg .
```

> [!IMPORTANT]
> A running server or release never picks up a new value. Rebuild after changing either variable.

The in-app assistant keeps the name "Mythweaver" regardless of these settings.
