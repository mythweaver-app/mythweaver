---
title: GeoIP
order: 6
description: Showing the place and network of each IP address on an account's moderation record.
---

An account's moderation record can show where each IP address it used is located and which network it belongs to. The data comes from MaxMind's free GeoLite2 City and ASN databases. Without them, nothing is downloaded and no locations are shown.

## To set up GeoIP

1. Create a GeoLite account at https://www.maxmind.com/en/geolite2/signup.
2. Under **Manage License Keys**, generate a licence key, and note the account ID shown on the account page.
3. Export `MYTHWEAVER_MAXMIND_ACCOUNT_ID` and `MYTHWEAVER_MAXMIND_LICENSE_KEY`.
4. Run `mix mythweaver.geoip.download`. `mix setup` runs it too. For a release, run it before `mix release`.
5. Restart the app the first time. After that, a re-downloaded database loads on its own.

## To keep the data current

Run `mix mythweaver.geoip.download` again at least every 30 days: the GeoLite licence requires current data. A database file less than a day old is kept unless you pass `--force`, since GeoLite accounts get 30 downloads a day.

## Reference

| Item | Detail |
| --- | --- |
| Database location | `priv/geoip`, or `MYTHWEAVER_GEOIP_DIR` (`/data/geoip` in the Docker image). |
| What is stored | Each IP address's location is stored with it on the account's record and refreshed every time the account is seen from that address. |
| Who sees it | Holders of `moderation.fingerprints`, on the account's moderation record. See [Moderation](moderation.md). |
