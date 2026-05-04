# cf-colo-watcher

A small bash script that shows which [Cloudflare](https://www.cloudflare.com/) colo (datacenter) is serving each request, along with cache status and TTFB.

## Why

Cloudflare routes each request through one of its edge locations (colos) based on anycast and current network conditions, so the same site can be served from different colos depending on the client's ISP and geography. This script gives you a live view of which colo is serving you, the cache status, TTFB, and total request time (one line per request), so you can see how performance varies across colos and over time.

Run it, switch VPN locations mid-run, and watch the colo change. The timing column tells the story.

## Example output

![cf-colo-watcher screenshot](screenshot.png)

```
Cloudflare colo watch
URL:      https://example.com
Interval: 5s
Started:  Mon May  4 14:25:00 EDT 2026
Switch your VPN/connection mid-run to compare colos. Ctrl+C to stop.

TIME     | COLO   | HTTP | CACHE        | TTFB      | TOTAL     | CF-RAY
---------+--------+------+--------------+-----------+-----------+--------------------------
14:25:03 | MIA    | 200  | HIT          |  0.218s   |   0.231s  | 9f6971eeff87f51d-MIA
14:25:09 | MIA    | 200  | HIT          |  0.241s   |   0.255s  | 9f69729eda573043-MIA
14:25:14 | MIA    | 200  | DYNAMIC      |  0.387s   |   0.402s  | 9f6970ea8abbdab9-MIA
14:25:20 | EWR    | 200  | HIT          |  0.176s   |   0.189s  | 9f6970ea8abbdab9-EWR
14:25:25 | EWR    | 200  | DYNAMIC      |  0.312s   |   0.331s  | 9f6970ea8abbdab9-EWR

Summary by colo:
COLO   | SAMPLES | AVG TTFB | MIN TTFB | MAX TTFB
-------+---------+----------+----------+----------
MIA    | 3       |  0.282s  |   0.218s |   0.387s
EWR    | 2       |  0.244s  |   0.176s |   0.312s
```

TTFB is color-coded in the live output:

- Green: under 500ms
- Yellow: 500ms to 1s
- Red: over 1s

## Usage

```bash
./colowatch.sh <url> [interval_seconds] [count]
```

- `url` - required, the URL to test
- `interval_seconds` - optional, seconds between requests (default 5)
- `count` - optional, stop after N requests (default 0 = run until Ctrl+C)

Examples:

```bash
./colowatch.sh https://example.com
./colowatch.sh https://example.com 3
./colowatch.sh https://example.com 5 20
./colowatch.sh https://example.com 5 50 | tee results.log
```

Press Ctrl+C at any time to stop and see the per-colo summary. If `count` is set, the summary prints automatically when it finishes.

## Install

```bash
curl -O https://raw.githubusercontent.com/haydenjames/cf-colo-watcher/main/colowatch.sh
chmod +x colowatch.sh
```

Or clone the repo:

```bash
git clone https://github.com/haydenjames/cf-colo-watcher.git
cd cf-colo-watcher
chmod +x colowatch.sh
```

## Requirements

- bash 4+ (for associative arrays in the summary)
- curl
- awk

Works on Linux out of the box. macOS ships with bash 3.2 by default, so install a newer bash via `brew install bash` and run with `/opt/homebrew/bin/bash ./colowatch.sh ...` (or `/usr/local/bin/bash` on Intel Macs).

## How it works

Each request to the URL returns a `cf-ray` header that ends with the colo code (e.g. `9f6971eeff87f51d-MIA` means Miami). The script extracts that, along with the `cf-cache-status` header and curl's timing measurements, and prints one line per request.

Tracking these over time, especially while switching VPN locations, gives you a per-colo picture of cache behavior and response time.

## Use cases

- Reproducing geography-specific user reports (different ISPs route to different colos)
- Measuring before/after impact of caching, Argo Smart Routing, or Tiered Cache changes
- Comparing cached (HIT) vs uncached (DYNAMIC) request behavior on your zones
- Capturing concrete TTFB and `cf-ray` data when working with support on routing questions
- Sanity-checking which colo a region is actually being served by

## Tips

- For comparison testing, run with `tee results.log` to keep a record
- Use a low interval (3 seconds) for short A/B tests, longer (10+) for sustained monitoring
- If you see a colo column showing `???`, the request failed before getting a Cloudflare response, check connectivity
- The script makes one curl per cycle and uses the response headers for both timing and ray ID, so each line represents a single round trip

## License

MIT
