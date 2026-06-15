# SNI + HOST Port Multiplexer

Route multiple services through port **443** (by SNI) and port **80** (by Host header) on a single VPS — without decrypting TLS.

Compatible with **3x-ui · s-ui · MTProxyMax · DSNS TM**

---

## Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alaaabd90/sni/main/sni-router.sh) --install
```

---

## Commands

```bash
sni              # open menu
sni update       # update to latest version
sni version      # show installed version
```

---

## How it works

| Port | Mode | Routing by |
|------|------|-----------|
| 443  | TCP passthrough (no decryption) | SNI field in TLS ClientHello |
| 80   | HTTP Layer 7 | Host header |

Each route forwards to a local inbound on a different port (e.g. `127.0.0.1:10443`). Your panel (3x-ui / s-ui) binds to `127.0.0.1` instead of `0.0.0.0`.
