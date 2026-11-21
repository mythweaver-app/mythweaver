---
title: Appearance
order: 3
description: Tint the app, pick its language and regional format, and restyle it with the site and user stylesheets.
---

The **Appearance** category of **Settings** at `/settings/appearance` changes how Mythweaver looks and reads for you: the color tint, the language of its text, how numbers and dates are written, the size of chat portraits, and your own CSS. Admins also set the site-wide defaults and the site stylesheet there. See [Settings](settings.md#appearance) for every setting in the category.

## To tint the app

1. Open **Settings** at `/settings/appearance`.
2. Drag **Primary hue** to the color you want. The page previews the hue as you move the slider.
3. Drag **Tint strength** to choose how strongly backgrounds, surfaces and borders take on that hue: 0 is neutral grey, 100 the default.

Both follow the usual cascade: your value, else the site's, else the built-in default (hue 263, strength 100). Light and dark mode follow your device's setting; the tint applies to both.

## To choose a language and regional format

The language (the app's text) and the regional format (how numbers, dates, times and money are written) are chosen separately. You can, for example, read the app in English with German dates.

1. Open **Settings** at `/settings/appearance`.
2. Under **Language and region**, pick a **Language** and a **Regional format**, or leave either on **Match my browser**.

### How the language is chosen

The first of these that gives an answer wins:

1. Your **Language** setting.
2. The first language your browser asks for that the app has a translation for.
3. The site's **Default language**, set by an admin.
4. English.

Only languages the app has a translation for are listed.

### How the regional format is chosen

1. Your **Regional format** setting.
2. Your browser's preferred region, matched to the closest one supported.
3. The site's **Default regional format**, set by an admin.
4. English.

### Text built for you in the background

Notifications, push messages and background job errors are written when you may not have a page open. They use your settings, and in place of the browser step they use the language and region your browser asked for the last time you visited.

## Custom stylesheets

Mythweaver loads two stylesheets of your own CSS on every page, after its own styles:

| Stylesheet | Address | Who writes it | Applies to |
| --- | --- | --- | --- |
| **Site stylesheet** | `/site.css` | Admins, on the **Site** tab | Everyone, signed-out pages included. |
| **Your stylesheet** | `/user.css` | Each user, for themselves | Only you, after the site stylesheet. |

Because your stylesheet loads last, its rules win over the site's when both set the same thing.

### To add your own CSS

1. Open **Settings** at `/settings/appearance`.
2. Under **Stylesheets**, type your CSS into **Your stylesheet**. It saves as you go and applies to the page.

For example, to set the whole app in a serif typeface:

```css
body {
  font-family: Georgia, serif;
}
```

> [!TIP]
> If a stylesheet breaks a page so badly you can't fix it, add `?safe_mode` to the page's address (for example `/settings/appearance?safe_mode`). The page then loads without your stylesheet, and you can edit or clear it.

### What user stylesheets may load

While **Restrict user stylesheets** is on (the default), your stylesheet may not load anything from outside the app: no `url()`, `image-set()`, `@import` or similar pointing elsewhere. Two exceptions apply:

- While **Allow third-party fonts** is on, you may `@import` a Google Fonts stylesheet, such as `@import url("https://fonts.googleapis.com/css2?family=Inter&display=swap");`. The font service sees each visitor's IP address.
- Origins an admin lists in **Extra stylesheet sources** are allowed for both stylesheets.

An admin can turn **Restrict user stylesheets** off to let users write any CSS. The site stylesheet is always served as written.

> [!NOTE]
> If an admin tightens the restriction after you saved a stylesheet that loads outside files, your stylesheet stops being applied. Its row shows "Not applied: it loads outside files, which the site no longer allows." Remove the outside loads to use it again.

## Chat avatar size

**Largest avatar width** and **Largest avatar height** cap how large a chat message's portrait or expression sprite grows, in pixels. A portrait keeps its 3:4 shape, so the height also limits its width.
