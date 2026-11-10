# Privacy policy

Kumo has no accounts and no ads, and it never sends your servers, links, browsing or traffic to the developers. It sends an anonymous usage count and, if something breaks, a crash report. Both are described below and both are turned off by one switch in *Settings → App settings*.

## Network requests Kumo makes

Kumo talks to other servers only for the features below. Each one is started by the app's normal use and can be turned off or avoided.

| When | Where | What is sent |
| --- | --- | --- |
| Checking for updates (on start and from *Settings → About*) | `api.github.com`, `github.com` | A request for the project's releases. The download of an update is a normal file download from GitHub. |
| Loading the free public server list (the *Public servers* group; it can be hidden in Settings) | `cdn.jsdelivr.net` and mirrors, `raw.githubusercontent.com` | A request for a public text file. |
| Downloading routing data when you pick *Direct countries* or turn on *Block ads and trackers* (the lists are fetched a few seconds after a connection is up, through it: the ad lists when they are a day old, or when you tap *Update now*) | `cdn.jsdelivr.net` and its mirrors (`fastly.`, `gcore.`, `testingcf.jsdelivr.net`), `raw.githubusercontent.com` | A request for public rule files. |
| Opening *What is my IP* or the *DNS leak test* (only when you do) | `api.ipify.org`, `ipwho.is`, `bash.ws` | Your address and the names looked up for the test. |
| Updating a subscription you added | The address you entered | A normal request for that address. |
| The *Speed test* tool (only when you press *Start the test*) | `speed.cloudflare.com` by default; if you choose another place, `*.speedtest.clouvider.net` (LibreSpeed, Frankfurt, Amsterdam or London) or `proof.ovh.net` (OVH) | A few small requests for the delay, then about eight seconds of download and, where the server takes one, about eight seconds of upload of zeros. With a VPN up the test goes through it, so the place sees the address your server's traffic leaves from; with none it sees your own address. The results are kept in a file on your device (the last 30 tests) and are never sent anywhere. |
| Measuring the speed of the best addresses in *Find a clean IP* (only when you turn it on, and only with a server) | `speed.cloudflare.com`, through your own server | A download of about 8 MB and/or an upload of 8 MB of zeros, which Cloudflare's speed test answers. Cloudflare sees the address your server's traffic leaves from. |
| Looking up the name of a server before connecting (off in *Settings → Network*) | `1.1.1.1` (Cloudflare), `8.8.8.8` (Google) | The name of the server you connect to (for example `server.example.com`), over encrypted DNS, so that your network's own resolver does not see it. Both are asked at once. So that a connection does not wait for it, this is also done ahead while Kumo is open and not connected: when you pick a server, and every 9 minutes for the server(s) a connection would use. If these cannot be reached, your system's own resolver is asked instead. |
| *Find a clean IP* (only when you start a scan) | The addresses of the ranges you scan (Cloudflare, Fastly or your own list), `www.cloudflare.com` (its list of ranges), and, only if you turn the options on, the pages `/cdn-cgi/trace` and `speed.cloudflare.com` of the addresses found | Plain connections and TLS handshakes to those addresses, and requests for the pages above. With a server, the test goes through that server like any use of it. Nothing is sent to the developers, and the results stay on your device. |
| Testing a server's real delay | `cp.cloudflare.com` (the address can be changed in Settings) | A small request sent through the server being tested. |
| *IP and DNS leak check* (only when you tap it) | `www.cloudflare.com` | A request for `/cdn-cgi/trace`. |
| Anonymous usage count (once a day, and when the app version changes; off in *Settings → App settings*) | `api.kumo-client.ir`, `kumo-api.kumoapp.workers.dev` | A salted hash of your device id (the raw id is never sent), your operating system and its version, the Kumo version, the language chosen in the app, your device's language and country setting (not where you are), your time zone, your processor, the maker and model of your device (for example *Dell XPS 15* or *MacBookPro18,3*; no serial number or computer name), the name of the release file you installed (for example `kumo-android-universal.apk`), and on Android the maker's interface (for example *One UI 6.1*) and on Linux the desktop (for example *GNOME*). The server does not store your IP address. When you turn the switch off, one last message says so and nothing more is sent. |
| Crash report (only when something breaks; off with the same switch as the usage count) | `api.kumo-client.ir`, `kumo-api.kumoapp.workers.dev` | The name of the error and the stack trace (where in the program it happened), the Kumo version, your system version, the maker and model of your device, the name of the release file, the page you were on, whether the VPN was connected, the same hashed device id as above, and the last lines of Kumo's own log. Before it is sent, links are cut to their scheme, and IP addresses, e-mail addresses, ids, long tokens, passwords, the names of your servers and subscriptions and your user name in folder paths are removed. Servers, subscription links, passwords and the contents of your files are never included. At most 10 a day. If you turn the switch off, waiting reports are deleted. |
| Using a VPN server | The servers in your list | Your traffic, as with any VPN. |

These servers (GitHub, jsDelivr, Cloudflare) see your IP address and request as any website does. Their own privacy policies apply to them.

## What is stored on your device

Your server list, subscriptions, settings, usage statistics and logs are kept in the app's private storage on your device. Backups are files you choose to create and can encrypt with a password. Uninstalling the app removes its data.

## Public servers

Public servers are run by unknown third parties and can see the traffic that is not encrypted end to end. Do not use them for sensitive activity.

## Changes

If this changes, the new version is published in this file in the repository.
