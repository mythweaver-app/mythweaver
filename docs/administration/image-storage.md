---
title: Image storage and proxies
order: 3
description: Where uploaded files are stored, which service resizes images, and how image links are protected.
---

Uploaded files (chat attachments and character avatars) are kept by a storage backend and, optionally, resized by an image proxy. You choose both with environment variables. A bad combination stops the server at boot and names the missing variable. For what users see, see [Images and attachments](../images/index.md).

## To choose a storage backend

Set `MYTHWEAVER_STORAGE`:

| Value | What it does |
| --- | --- |
| `local` (default) | Writes files under `MYTHWEAVER_UPLOADS_DIR` (required in production; `priv/uploads` otherwise) and serves them at `/uploads`. |
| `s3` | Stores files in an S3-compatible bucket (AWS S3, Tigris, MinIO). Browsers upload straight to the bucket. |

For S3, set `MYTHWEAVER_S3_BUCKET` (or `BUCKET_NAME`), `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` and `AWS_ENDPOINT_URL_S3`. Files are read through presigned links, so the bucket can stay private.

> [!IMPORTANT]
> The bucket's CORS policy must allow `POST` from the app's origin, or browser uploads fail.

## To choose an image proxy

Set `MYTHWEAVER_IMAGE_PROXY`:

| Value | What it does | Variables it needs |
| --- | --- | --- |
| `none` (default) | The browser scales the originals itself. | None |
| `xtandard` | [xtandard-image](https://me.xantiagoma.com/xtandard-image/) ("xi") resizes images, makes video poster frames and PDF previews, and reports blurhashes. | `MYTHWEAVER_XI_URL`, `MYTHWEAVER_XI_KEY`, `MYTHWEAVER_XI_SALT`, `MYTHWEAVER_XI_ENCRYPTION_KEY`, and `MYTHWEAVER_XI_SOURCE_PREFIX` with local storage |
| `cloudflare` | Cloudflare image transformations. | `MYTHWEAVER_CLOUDFLARE_ZONE_URL`; `MYTHWEAVER_UPLOADS_ORIGIN_SECRET` with local storage |
| `fastly` | Fastly image optimization. | `MYTHWEAVER_FASTLY_BASE_URL` (required with S3); `MYTHWEAVER_UPLOADS_ORIGIN_SECRET` with local storage |

The proxy also scales every image sent to a vision model into a 2048 px box. With `none`, or when the proxy fails, the original is sent.

The server fetches those scaled images (and xi's blurhashes) itself. When the browser's proxy address is relative or unreachable from the server, set `MYTHWEAVER_XI_INTERNAL_URL` to an address the server can reach.

### Setting up xtandard-image

1. Generate three secrets with `openssl rand -hex 32`, one each for the signing key, the signing salt and the encryption key. Never reuse the public development values from `compose.yml`.
2. Give xi the same values: `XI_SIGNING_KEYS` = `MYTHWEAVER_XI_KEY`, `XI_SIGNING_SALTS` = `MYTHWEAVER_XI_SALT`, `XI_ENCRYPTION_KEYS` = `MYTHWEAVER_XI_ENCRYPTION_KEY` (16, 24 or 32 bytes, hex).
3. Configure only your own source in xi (`XI_SOURCES`). With local storage, point an `fs` source at the uploads directory and set `MYTHWEAVER_XI_SOURCE_PREFIX` to match, for example `xi://uploads/` for a source named `uploads`.
4. Set `XI_SECURITY_UNSIGNED_POLICY=deny`, so xi resizes only links the app signed.
5. Set `XI_CACHE_HEADERS_TTL` to at most the link window (below), so no cache keeps an image after its link expires.

`compose.yml` shows a working xi service with these settings.

Only xi draws stills (a video's poster frame and the first page of a PDF). It also reports each new image's blurhash, which inline images paint while they load. Images stored before you turned xi on have no blurhash.

### Setting up Cloudflare or Fastly over local storage

1. Set `MYTHWEAVER_UPLOADS_ORIGIN_SECRET` to a long random value.
2. Make the CDN send it as an `x-mythweaver-origin-secret` header on every request it forwards to `/uploads`: a request-header Transform Rule in Cloudflare, or `set bereq.http.x-mythweaver-origin-secret` in Fastly VCL.

`/uploads` then refuses images to any request without the header, so nobody can fetch the originals around the CDN.

> [!NOTE]
> Cloudflare and Fastly don't sign transformation URLs themselves. Over local storage the app checks the signed source link when they fetch it, and they cache it under the full link. Fastly with `MYTHWEAVER_FASTLY_BASE_URL` serves unsigned URLs: to make them expire you need Fastly's own token check (VCL token authentication). Checking at Cloudflare's edge needs a WAF token rule (`is_timed_hmac_valid_v0`, Pro plan and up).

## How image links are protected

Every attachment link the app renders (an `/uploads/<token>` link, an S3 presigned link, or an xi URL) is sealed or signed and expires.

- A link is valid for one to two link windows. Set the window in seconds with `MYTHWEAVER_IMAGE_LINK_WINDOW` (default `86400`, one day; at most `302400` with S3). Within one window the link stays the same, so browsers and CDNs can cache it.
- An `/uploads` token encrypts the storage key together with the expiry, using a key derived from `SECRET_KEY_BASE`, so the link reveals neither.
- xi URLs carry the expiry in their signature and the source encrypted.
- Who may see a file is decided when the page shows the link. Anyone holding the link can open it until it expires.

What `/uploads` serves depends on the proxy:

| Proxy | Images | Other files |
| --- | --- | --- |
| `none` | Served from `/uploads`. | Served from `/uploads`. |
| `xtandard` | Only through xi, the full-size original included. `/uploads` refuses images. | Served from `/uploads`, since xi passes only images. |
| `cloudflare` or `fastly` over local storage | Only to requests carrying the origin secret. | Served from `/uploads`. |

## Upload limits

| Limit | Default | How to change it |
| --- | --- | --- |
| Size of each image | 20 MB | `MYTHWEAVER_MAX_UPLOAD_BYTES` (bytes). |
| Image formats | PNG, JPEG, WebP | Fixed. GIF is refused, since several vision APIs reject it. |
| A user's total storage | Unlimited | The `quota.upload_bytes` permission; see [Users, groups and permissions](users-and-permissions.md). |
| Which file kinds a user may attach | Granted by default | The `uploads.*` permissions. |
