# Privacy policy

Kumo does not collect, store or send any data about you to the developers. There are no accounts, no analytics, no ads and no crash reporting.

## Network requests Kumo makes

Kumo talks to other servers only for the features below. Each one is started by the app's normal use and can be turned off or avoided.

| When | Where | What is sent |
| --- | --- | --- |
| Checking for updates (on start and from *Settings → About*) | `api.github.com`, `github.com` | A request for the project's releases. The download of an update is a normal file download from GitHub. |
| Loading the free public server list (the *Public servers* group; it can be hidden in Settings) | `cdn.jsdelivr.net` and mirrors, `raw.githubusercontent.com` | A request for a public text file. |
| Downloading routing data when you pick *Direct countries* or turn on *Block ads and trackers* | `cdn.jsdelivr.net`, `raw.githubusercontent.com` | A request for public rule files. |
| Opening *What is my IP* or the *DNS leak test* (only when you do) | pi.ipify.org, ipwho.is, ash.ws | Your address and the names looked up for the test. |
| Updating a subscription you added | The address you entered | A normal request for that address. |
| Testing a server's real delay | `cp.cloudflare.com` (the address can be changed in Settings) | A small request sent through the server being tested. |
| *IP and DNS leak check* (only when you tap it) | `www.cloudflare.com` | A request for `/cdn-cgi/trace`. |
| Using a VPN server | The servers in your list | Your traffic, as with any VPN. |

These servers (GitHub, jsDelivr, Cloudflare) see your IP address and request as any website does. Their own privacy policies apply to them.

## What is stored on your device

Your server list, subscriptions, settings, usage statistics and logs are kept in the app's private storage on your device. Backups are files you choose to create and can encrypt with a password. Uninstalling the app removes its data.

## Public servers

Public servers are run by unknown third parties and can see the traffic that is not encrypted end to end. Do not use them for sensitive activity.

## Changes

If this changes, the new version is published in this file in the repository.