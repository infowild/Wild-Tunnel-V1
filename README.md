# Wild Tunnel v2

**English** | [فارسی](#wild-tunnel-v2-فارسی)

A single-file installer for a tunnel with **one Local forwarder and one or more
Remote receivers**, designed to forward ports from a local server (e.g. inside
Iran) to servers abroad. It supports multiple transport protocols powered by two
cores:

- **Xray-core** — `VLESS`, `VMESS`, `Trojan`, `Shadowsocks`, `SOCKS`
- **Hysteria2** (`apernet/hysteria`) — native UDP transport with Salamander obfuscation

TCP and UDP are relayed on the selected ports, except when Shadowsocks or SOCKS uses TLS/REALITY: in that mode UDP is deliberately disabled because Xray would send native UDP outside the camouflage layer.

---

## How it works

```
                    Tunnel (encrypted)
 ┌──────────────┐   VLESS / VMESS / Trojan   ┌──────────────┐
 │ Local server │   Shadowsocks / SOCKS      │ Remote server│
 │   (Iran)     │ ─────────────────────────► │  (Foreign)   │
 │  Forwarder   │   Hysteria2 (UDP)          │   Receiver   │
 └──────────────┘                            └──────────────┘
   listens on                                  terminates the tunnel and
   your chosen ports                           connects to 127.0.0.1:<port>
   (direct Xray listeners; TUN fallback)            on its own side
```

- **Remote server (Receiver):** terminates the tunnel and forwards traffic to
  `127.0.0.1:<port>` on itself (via Xray `freedom` outbound, or Hysteria2's built-in
  proxy). This is where your panel/service actually listens.
- **Local server (Forwarder):** Xray listens directly on every forwarded port with a dedicated `dokodemo-door` inbound and sends the stream into one dispatcher. This default path has no TUN, NAT, or tun2socks hop. Xray locations are direct outbounds; every Hysteria2 location runs as a separate loopback-only SOCKS client and is selected by the same dispatcher. The previous TUN pipeline remains available as the `tun-legacy` compatibility mode.

The tunnel core and direct listeners run as `wild-tunnel`. Only `tun-legacy` mode also runs `wild-forward` to manage tun2socks, the TUN device, and scoped firewall rules. The systemd units are generated at install time and hardened with private temporary storage, a read-only system filesystem, and a restrictive umask.

---

## Requirements

- Ubuntu / Debian on **x86_64/amd64** with `systemd`
- `root` access (run with `sudo` or as root)
- One Local server and one or more Remote servers
- For a **real** TLS certificate: a domain pointing at the remote server and TCP
  port **80** free (Let's Encrypt standalone challenge)

Before doing anything else, the installer updates the package lists and installs
all prerequisites it needs (`unzip`, `jq`, `openssl`, `uuid-runtime`, `wget`,
`iproute2`, `iptables`, `cron`, `python3`, `python3-yaml`, and `certbot` on demand).

**No conflict with the Sanaei / 3x-ui panel.** Everything is namespaced
(`wild-tunnel` service, `/usr/local/bin/wild-xray`, `/etc/wild-tunnel`, `wild`
command), so it never touches the panel's `x-ui` service, `/usr/local/x-ui`,
`/etc/x-ui` or `/usr/bin/x-ui`. It does not modify the panel's files or services. A forwarded port in direct mode must be free for Xray to bind. The optional `tun-legacy` mode adds narrowly scoped iptables rules while it runs; existing sysctl values are saved and restored when that forwarder stops or is removed.

---

## Installation

### Easy install (one-liner)

Run this on **each** server (as root) and follow the prompts:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/Wild-Tunnel-V1/wild-tunnel-v2/install.sh)
```

> Use `bash <(curl ...)`, **not** `curl ... | bash` — the installer is interactive
> and piping would break its prompts. If `curl` is missing:
> `apt-get update && apt-get install -y curl`.

### Manual install

Alternatively, clone the repository and run the installer:

```bash
git clone --branch wild-tunnel-v2 --single-branch https://github.com/infowild/Wild-Tunnel-V1.git wild-tunnel
cd wild-tunnel
chmod +x install.sh
sudo ./install.sh
```

### Upgrade an existing installation without uninstalling

Download/run the v2 installer above on the **Remote server first**, then on the
**Local (Iran) server**. Do not choose either Install option. Use:

```text
3) Management menu
7) Edit Configuration
a) Apply changes
```

`Apply` regenerates the service/config from `/etc/wild-tunnel/wild.conf` while
preserving the saved credentials, REALITY keys, and reusable certificate. On an
older Local installation, open **Manage Locations / Load Balancing** once to
migrate the current connection into the first location; select `direct` under
**Forwarding Mode** if you also want the v2 forwarding path, then Apply. If
`/etc/wild-tunnel/wild.conf` does not exist, stop: the existing installation has
no state that v2 can migrate safely.

You will be asked to choose a role:

```
1) Install Remote Server (Foreign - Receiver)
2) Install Local Server (Iran - Forwarder)
3) Uninstall Wild Tunnel
```

### 1. Set up the Remote server first

Choose option **1**, then:

1. Enter one or more **Tunnel Ports**, for example `443,2053,8443`. Inclusive ranges are also accepted; Hysteria2 uses them for native port hopping, while Xray expands at most 64 ports into separate listeners.
2. Pick a **protocol** (1–6).
3. Provide/auto-generate the credentials (UUID or password, plus obfuscation
   password for Hysteria2).
4. When TLS is selected (or when using Hysteria2), choose between a **real Let's Encrypt certificate** (needs a domain) or an auto-generated **self-signed** certificate. Self-signed TLS is pinned for authentication, but is **not recommended for anti-DPI**; prefer REALITY or a real-domain certificate.

At the end the installer prints all the details (port, protocol, UUID/password,
obfuscation password, SNI). **Save them** — you need them for the local server.

### 2. Set up the Local server

Choose option **2**, then:

1. Give the first location a name and enter its **Remote Server IP**.
2. Enter the **same tunnel port(s)** and **same protocol/credentials** as that remote.
3. Enter the **ports to forward** locally (comma-separated, e.g. `2053,8443`). These forwarded service ports are global, independent of the tunnel transport ports, and must be free on the local server in the default direct mode.
4. For TLS/Hysteria2, enter the remote domain or the SHA-256 certificate pin printed by the remote installer. Self-signed connections are never accepted without a pin.
5. Answer **yes** to “Add another remote location?” to mix additional Xray or Hysteria2 locations in the same installation.

Once finished, connecting to `LOCAL_IP:<port>` reaches `127.0.0.1:<port>` on the
remote server through the tunnel.

### Multi-location and multi-port

- Multi-location is configured only on the **Local (Iran) server**, which aggregates several independent Remote receivers. Install option **1** separately on every Remote server; it intentionally has no “add location” prompt. Install option **2** on Iran asks `Add another remote location now?` after the first location's forwarding ports.
- A location is one remote endpoint plus its protocol, credentials, security, and tunnel-port list. Locations may freely mix Xray protocols and Hysteria2.
- Each Xray tunnel port becomes an independent outbound path. Hysteria2 accepts comma lists/ranges as native port hopping and each Hysteria location gets its own managed client instance.
- The default `leastLoad` strategy uses Xray health observations and keeps a fallback path when more than one eligible path exists. A single-path installation routes directly and does not send periodic health probes. `leastPing`, `roundRobin`, and `random` are also available under `wild` → **Edit configuration** → **Manage Locations / Load Balancing**.
- TCP and UDP use separate eligible-path pools, so a TCP-only location is never selected for UDP.
- New installations use `direct` forwarding: Xray binds the service ports itself and bypasses the userspace TUN stack. `tun-legacy` can be selected from the edit menu if direct binding is incompatible with another local service.
- Existing single-location local installations are migrated automatically to `/etc/wild-tunnel/locations.json` the first time the new edit/apply path is used.

---

## Protocols

| # | Protocol     | Core       | Transport | TLS                         |
|---|--------------|------------|-----------|-----------------------------|
| 1 | VLESS        | Xray-core  | tcp/ws/grpc/http/httpupgrade | none/TLS/REALITY |
| 2 | VMESS        | Xray-core  | tcp/ws/grpc/http/httpupgrade | none/TLS/REALITY |
| 3 | Trojan       | Xray-core  | tcp/ws/grpc/http/httpupgrade | none/TLS/REALITY |
| 4 | Shadowsocks  | Xray-core  | TCP/UDP*  | cipher + optional TLS/REALITY |
| 5 | SOCKS        | Xray-core  | TCP/UDP*  | optional TLS/REALITY |
| 6 | Hysteria2    | Hysteria   | UDP       | TLS + Salamander obfuscation|

> Pinned core versions: **Xray `v26.3.27`**, **Hysteria `v2.9.3`**.

### Selectable encryption

Two protocols let you pick the in-tunnel cipher (choose the **same** value on both
servers):

- **Shadowsocks** — classic AEAD: `aes-256-gcm`, `aes-128-gcm`,
  `chacha20-ietf-poly1305`, `xchacha20-ietf-poly1305`; and Shadowsocks-2022:
  `2022-blake3-aes-256-gcm`, `2022-blake3-aes-128-gcm`,
  `2022-blake3-chacha20-poly1305`. The 2022 ciphers require a Base64 pre-shared key
  of an exact length, which the installer generates for you automatically.
- **VMESS** — encryption (`security`): `auto`, `aes-128-gcm`, `chacha20-poly1305`,
  `none`, `zero`.

### Security, Transmission & REALITY

For **VLESS / VMESS / Trojan** the installer also lets you pick a transport and a
security layer (again, use the **same** choices on both servers):

- **Transmission (network):** `tcp`, `ws`, `grpc`, `http` (HTTP/2), `httpupgrade`
  (with the relevant `path` / `host` / `serviceName` sub-settings).
- **Security:** `none`, `tls`, or `reality`.
  - **REALITY** — the installer runs `xray x25519` on the remote to generate a
    key pair and a random `shortId`, and asks for a camouflage `dest` / `serverName`
    (default `dl.google.com`). It prints the **public key**, **shortId** and
    **SNI** to enter on the local server. The raw generator output is also shown so
    you can copy values manually if needed. Before generating the config, the pinned
    Xray binary runs `xray tls ping` against the resolved target IP and requires a
    TLS 1.3 handshake. This cannot prove ASN ownership: for stronger camouflage,
    manually choose a target hosted in the same ASN as the remote server.
  - **TLS** — real Let's Encrypt certificate or an auto self-signed one. Real-domain
    TLS enables `rejectUnknownSni`; self-signed TLS remains certificate-pinned but is
    not recommended as an anti-DPI profile.
- **VLESS Encryption** (VLESS only) — post-quantum ML-KEM encryption via
  `xray vlessenc`; the `decryption` string goes on the remote and the printed
  `encryption` string on the local server.

Guardrails: `xtls-rprx-vision` flow is only applied to VLESS over `tcp` with `tls`/`reality`, and is never combined with VLESS Encryption. REALITY with `ws` or `httpupgrade` is rejected because Xray does not support those combinations; `grpc` / `http` warn when security is `none`.

\* Shadowsocks/SOCKS UDP is available only with `security: none`; it is disabled under TLS/REALITY to avoid leaking native UDP outside the selected transport.

### Upload performance tuning

The default direct forwarder removes the shared `iptables → TUN → tun2socks → SOCKS` ingress path and hands each accepted stream directly to Xray. This reduces userspace TCP processing, copies, and context switches—especially important on a 1-vCPU server. If the kernel exposes BBR, Xray selects it only for the outbound tunnel socket; the host-wide congestion-control default is not changed.

The optional `tun-legacy` fallback retains the previous 4 MB tun2socks receive window, TCP receive auto-tuning, and enlarged TUN transmit queue.

Each local Hysteria client uses its BBR `aggressive` profile for upload and leaves explicit bandwidth limits unset. Reconfigure that location from `wild` → Edit configuration → Manage Locations if `standard` or `conservative` performs better on a lossy route.

`SOCKS` is unencrypted, and `Hysteria2` (separate core) relies on TLS + Salamander
obfuscation.

---

## Service management

After installation a `wild` command is available anywhere on the server. Just run:

```bash
wild
```

It opens a management menu:

```
1) Status
2) Restart (manual)
3) Stop
4) Start
5) Live logs
6) Show config
7) Edit configuration
8) Schedule auto-restart (cron)
9) Remove scheduled restart
10) Uninstall
11) Back to main menu
```

Option **7** edits the saved installation and regenerates a validated configuration. Option **8** installs a tagged `crontab` restart schedule; option **9** removes only that tagged entry.

To move an installation created before v2 onto the faster path, run the latest installer once, then open `wild` → **Edit configuration** → **Forwarding Mode**, select `direct`, and Apply. Legacy installations intentionally remain on `tun-legacy` until this explicit switch.

Or use systemd directly:

```bash
systemctl status wild-tunnel      # check status
systemctl restart wild-tunnel     # restart
journalctl -u wild-tunnel -f      # follow logs
systemctl status 'wild-hysteria-client@*'  # Hysteria location clients
```

Configuration lives in `/etc/wild-tunnel/`:

- Xray protocols → `config.json`
- Remote Hysteria2 receiver → `config.yaml`
- Local location database → `locations.json`
- Per-location Hysteria2 clients → `locations/loc-N.yaml`
- Editable installation state → `wild.conf`

These files are written atomically with mode `0600`. JSON is parsed by `jq` and semantically tested by Xray before service restart; Hysteria YAML is parsed with PyYAML.

When a real certificate is used, a Let's Encrypt **deploy hook** at
`/etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh` restarts the service after
each automatic renewal, so the tunnel never serves an expired certificate.

---

## Uninstall

Run the installer and choose Uninstall (option **3** before installation, or the management-menu option afterward). It stops both services, restores forwarding sysctls, removes scoped firewall rules, the core/helper binaries, manager command, configuration, cron entry, and renewal hook. Let's Encrypt certificates under `/etc/letsencrypt` are left
untouched.

---

## Security notes

- Every Xray protocol (`VLESS`, `VMESS`, `Trojan`, `Shadowsocks`, `SOCKS`) can be
  given a **Transmission** (tcp/ws/grpc/http/httpupgrade) and a **Security** layer
  (`none`/`tls`/`reality`).
- With `security: none` the tunnel is trivially fingerprinted. Under Iran's DPI the
  connection is established and the upload passes, but the **first downstream data
  packet is dropped** and the tunnel appears to hang. This is not a bug: adding
  **REALITY** to the exact same protocol/port fixes it. Prefer **REALITY**.
- `Shadowsocks` and `SOCKS` forward **TCP only** when tls/reality is enabled: their
  UDP would bypass the transport unmasked (Xray does not apply streamSettings to
  their native UDP path without XUDP).
- Self-signed certificates use `CN=bing.com`. Xray v26 removed `allowInsecure`, so the remote prints a **TLS cert SHA256 pin** for `pinnedPeerCertSha256`. Hysteria2 uses the same trust model through `pinSHA256`; `insecure` is enabled only together with that pin. Pinning protects server authentication, but the self-signed handshake remains fingerprintable and is not recommended for anti-DPI.
- Real-domain Xray TLS rejects unknown SNI. The Hysteria server ACL permits only the forwarding sentinel and the exact health-check destination, then ends with `reject(all)`; authenticated tunnel users cannot use it as a general-purpose proxy.
- Release assets for Xray, Hysteria, and tun2socks are version-pinned and SHA-256 verified before atomic installation. Configuration/state files and generated private keys inherit a restrictive `umask 077`.

---

## License

Released under the [MIT License](LICENSE).

---
---

<div dir="rtl">

# Wild Tunnel v2 (فارسی)

[English](#wild-tunnel-v2) | **فارسی**

یک نصب‌کنندهٔ تک‌فایلی برای ساخت تونل با **یک فورواردر Local و یک یا چند Receiver
خارج** که پورت‌ها را از یک سرور محلی (مثلاً داخل ایران) به سرورهای خارج منتقل
می‌کند. از چند پروتکل با دو هستهٔ مختلف پشتیبانی می‌کند:

- **Xray-core** — پروتکل‌های `VLESS`، `VMESS`، `Trojan`، `Shadowsocks`، `SOCKS`
- **Hysteria2** (`apernet/hysteria`) — انتقال بومی روی UDP با اوبفوسکیشن Salamander

ترافیک TCP و UDP روی پورت‌های انتخاب‌شده عبور داده می‌شود؛ فقط در Shadowsocks/SOCKS همراه TLS یا REALITY، مسیر UDP عمداً غیرفعال است، چون UDP بومی Xray از لایهٔ استتار عبور نمی‌کند.

---

## نحوهٔ کارکرد

```
                    تونل (رمزنگاری‌شده)
 ┌──────────────┐   VLESS / VMESS / Trojan   ┌──────────────┐
 │  سرور محلی    │   Shadowsocks / SOCKS      │   سرور خارج   │
 │   (ایران)     │ ─────────────────────────► │   (Foreign)  │
 │  فورواردر     │   Hysteria2 (UDP)          │   گیرنده     │
 └──────────────┘                            └──────────────┘
   روی پورت‌های                                 تونل را می‌بندد و به
   انتخابی شما گوش می‌دهد                        127.0.0.1:<port> سمت
   (listener مستقیم Xray؛ TUN به‌عنوان fallback)   خودش وصل می‌شود
```

- **سرور خارج (گیرنده):** تونل را دریافت می‌کند و ترافیک را به `127.0.0.1:<port>` روی
  خودش می‌فرستد (از طریق outbound نوع `freedom` در Xray یا پروکسی داخلی Hysteria2).
  پنل/سرویس واقعی شما این‌جا گوش می‌دهد.
- **سرور محلی (فورواردر):** Xray با inbound نوع `dokodemo-door` مستقیماً روی هر Forward Port گوش می‌دهد و جریان را وارد dispatcher مرکزی می‌کند؛ در مسیر پیش‌فرض دیگر TUN، NAT یا tun2socks وجود ندارد. locationهای Xray مستقیماً outbound هستند و برای هر location از نوع Hysteria2 یک کلاینت مستقل با SOCKS فقط روی loopback اجرا می‌شود. مسیر قبلی با نام `tun-legacy` برای سازگاری و rollback باقی مانده است.

هستهٔ تونل و listenerهای مستقیم با یونیت `wild-tunnel` اجرا می‌شوند. فقط در حالت `tun-legacy` یونیت دوم `wild-forward`، tun2socks، رابط TUN و قوانین محدود فایروال را مدیریت می‌کند. یونیت‌ها هنگام نصب تولید و با filesystem سیستمی read-only، فضای موقت خصوصی و umask محدود سخت‌سازی می‌شوند.

---

## پیش‌نیازها

- اوبونتو / دبیان **x86_64/amd64** با `systemd`
- دسترسی `root` (با `sudo` یا کاربر root اجرا کنید)
- یک سرور Local و یک یا چند سرور Remote
- برای گواهی TLS **واقعی**: یک دامنه که به IP سرور خارج اشاره کند و پورت TCP شمارهٔ
  **۸۰** آزاد باشد (چالش standalone در Let's Encrypt)

نصب‌کننده پیش از هر کاری، لیست پکیج‌ها را آپدیت و همهٔ پیش‌نیازهای موردنیازش را نصب
می‌کند (`unzip`، `jq`، `openssl`، `uuid-runtime`، `wget`، `iproute2`، `iptables`، `cron`، `python3`، `python3-yaml` و در صورت نیاز `certbot`).

**بدون تداخل با پنل سنایی / 3x-ui.** همه‌چیز در namespace جدا است (سرویس
`wild-tunnel`، مسیر `/usr/local/bin/wild-xray`، کانفیگ `/etc/wild-tunnel`، دستور
`wild`)، پس به سرویس `x-ui` پنل و مسیرهای `/usr/local/x-ui`، `/etc/x-ui` و `/usr/bin/x-ui` دست نمی‌زند. بااین‌حال Forward Port در حالت مستقیم باید برای bind شدن Xray آزاد باشد. حالت اختیاری `tun-legacy` هنگام اجرا قوانین کاملاً محدود iptables می‌افزاید؛ مقادیر قبلی sysctl ذخیره و هنگام توقف/حذف فورواردر بازیابی می‌شوند.

---

## نصب

### نصب آسان (تک‌خطی)

این دستور را روی **هر دو** سرور (با کاربر root) اجرا کنید و به سؤال‌ها پاسخ دهید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/Wild-Tunnel-V1/wild-tunnel-v2/install.sh)
```

> از فرم `bash <(curl ...)` استفاده کنید، **نه** `curl ... | bash` — چون نصب‌کننده
> تعاملی است و حالت pipe سؤال‌ها را خراب می‌کند. اگر `curl` نصب نبود:
> `apt-get update && apt-get install -y curl`.

### نصب دستی

به‌جای آن می‌توانید مخزن را کلون کنید و نصب‌کننده را اجرا کنید:

```bash
git clone --branch wild-tunnel-v2 --single-branch https://github.com/infowild/Wild-Tunnel-V1.git wild-tunnel
cd wild-tunnel
chmod +x install.sh
sudo ./install.sh
```

### ارتقای نصب موجود بدون Uninstall

نصب‌کنندهٔ v2 بالا را ابتدا روی **سرور خارج** و سپس روی **سرور ایران** دریافت و اجرا
کنید. گزینه‌های Install را دوباره انتخاب نکنید؛ از مسیر زیر استفاده کنید:

```text
3) Management menu
7) Edit Configuration
a) Apply changes
```

گزینهٔ `Apply` سرویس و کانفیگ را از روی `/etc/wild-tunnel/wild.conf` بازسازی می‌کند و
اطلاعات ورود، کلیدهای REALITY و گواهی قابل‌بازیابی فعلی را نگه می‌دارد. در نصب Local
قدیمی، یک‌بار وارد **Manage Locations / Load Balancing** شوید تا اتصال فعلی به
location اول مهاجرت کند؛ برای فعال‌کردن مسیر forwarding نسخهٔ v2 نیز
**Forwarding Mode** را روی `direct` بگذارید و سپس Apply کنید. اگر فایل
`/etc/wild-tunnel/wild.conf` وجود ندارد، ادامه ندهید؛ نصب فعلی state قابل‌مهاجرت امن
ندارد.

از شما خواسته می‌شود یک نقش انتخاب کنید:

```
1) Install Remote Server (Foreign - Receiver)
2) Install Local Server (Iran - Forwarder)
3) Uninstall Wild Tunnel
```

### ۱. ابتدا سرور خارج را راه‌اندازی کنید

گزینهٔ **۱** را انتخاب کنید، سپس:

1. یک یا چند **پورت تونل** وارد کنید؛ مثلاً `443,2053,8443`. بازهٔ شامل دو سر نیز پذیرفته می‌شود: Hysteria2 از آن برای port hopping بومی استفاده می‌کند و Xray حداکثر ۶۴ پورت را به listenerهای جدا گسترش می‌دهد.
2. یک **پروتکل** انتخاب کنید (۱ تا ۶).
3. اطلاعات ورود را وارد یا به‌صورت خودکار بسازید (UUID یا پسورد، و برای Hysteria2
   پسورد اوبفوسکیشن).
4. هنگام انتخاب TLS (یا Hysteria2)، بین **گواهی واقعی Let's Encrypt** و گواهی **self-signed** انتخاب کنید. TLS خودامضا با pin احراز هویت می‌شود، اما برای **مقاومت در برابر DPI توصیه نمی‌شود**؛ REALITY یا گواهی دامنهٔ واقعی را ترجیح دهید.

در پایان، نصب‌کننده تمام جزئیات (پورت، پروتکل، UUID/پسورد، پسورد اوبفوسکیشن، SNI) را چاپ
می‌کند. **آن‌ها را ذخیره کنید** — برای سرور محلی لازم‌شان دارید.

### ۲. سرور محلی را راه‌اندازی کنید

گزینهٔ **۲** را انتخاب کنید، سپس:

1. برای location اول یک نام انتخاب و **IP سرور خارج** را وارد کنید.
2. **همان پورت یا پورت‌های تونل** و **همان پروتکل/اطلاعات ورود** آن سرور خارج را وارد کنید.
3. **پورت‌های سرویس که باید فوروارد شوند** را وارد کنید (با کاما، مثلاً `2053,8443`). این پورت‌ها سراسری‌اند، با پورت انتقال تونل تفاوت دارند و در حالت مستقیم پیش‌فرض باید روی سرور ایران آزاد باشند.
4. برای TLS/Hysteria2، دامنهٔ واقعی یا pin گواهی SHA-256 چاپ‌شده روی سرور خارج را وارد کنید. اتصال self-signed بدون pin پذیرفته نمی‌شود.
5. برای افزودن سرورهای دیگر به سؤال **Add another remote location?** پاسخ `y` بدهید؛ Xray و Hysteria2 را می‌توان در یک نصب با هم ترکیب کرد.

پس از پایان، اتصال به `LOCAL_IP:<port>` از طریق تونل به `127.0.0.1:<port>` روی سرور خارج
می‌رسد.

### مولتی‌لوکیشن و مولتی‌پورت

- مولتی‌لوکیشن فقط روی **سرور ایران (Local)** تنظیم می‌شود؛ این سرور چند Receiver مستقل خارج را تجمیع می‌کند. گزینهٔ نصب **۱** را جداگانه روی هر سرور خارج اجرا کنید؛ سمت خارج عمداً سؤال افزودن location ندارد. گزینهٔ نصب **۲** روی ایران، بعد از Forward Portهای location اول سؤال `Add another remote location now?` را نمایش می‌دهد.
- هر location شامل endpoint خارج، پروتکل، اطلاعات ورود، امنیت و فهرست پورت‌های تونل خودش است؛ locationها می‌توانند ترکیبی از پروتکل‌های Xray و Hysteria2 باشند.
- هر پورت Xray یک مسیر outbound مستقل می‌شود. Hysteria2 فهرست/بازهٔ پورت را به‌صورت port hopping بومی استفاده می‌کند و برای هر location آن یک کلاینت systemd جدا ساخته می‌شود.
- استراتژی پیش‌فرض `leastLoad` وقتی بیش از یک مسیر واجدشرایط وجود دارد با health observation خود Xray مسیر سالم‌تر را انتخاب و fallback نگه می‌دارد. نصب تک‌مسیر مستقیم route می‌شود و health probe دوره‌ای نمی‌فرستد. گزینه‌های `leastPing`، `roundRobin` و `random` نیز از مسیر `wild` → **Edit configuration** → **Manage Locations / Load Balancing** در دسترس‌اند.
- pool مسیرهای TCP و UDP جداست؛ در نتیجه location فقط-TCP هیچ‌وقت برای UDP انتخاب نمی‌شود.
- نصب جدید به‌صورت پیش‌فرض از forwarding حالت `direct` استفاده می‌کند: خود Xray پورت‌های سرویس را bind می‌کند و پشتهٔ TUN کاربرانpace حذف می‌شود. اگر bind مستقیم با سرویس محلی دیگری ناسازگار بود، `tun-legacy` از منوی Edit قابل انتخاب است.
- نصب‌های تک‌لوکیشن قدیمی در اولین Edit/Apply به‌صورت خودکار به `/etc/wild-tunnel/locations.json` مهاجرت می‌کنند.

---

## پروتکل‌ها

| # | پروتکل       | هسته       | انتقال    | TLS                          |
|---|--------------|------------|-----------|------------------------------|
| ۱ | VLESS        | Xray-core  | tcp/ws/grpc/http/httpupgrade | none/TLS/REALITY |
| ۲ | VMESS        | Xray-core  | tcp/ws/grpc/http/httpupgrade | none/TLS/REALITY |
| ۳ | Trojan       | Xray-core  | tcp/ws/grpc/http/httpupgrade | none/TLS/REALITY |
| ۴ | Shadowsocks  | Xray-core  | TCP/UDP*  | cipher + TLS/REALITY اختیاری |
| ۵ | SOCKS        | Xray-core  | TCP/UDP*  | TLS/REALITY اختیاری |
| ۶ | Hysteria2    | Hysteria   | UDP       | TLS + اوبفوسکیشن Salamander   |

> نسخه‌های ثابت هسته: **Xray نسخهٔ `v26.3.27`**، **Hysteria نسخهٔ `v2.9.3`**.

### رمزنگاری قابل انتخاب

دو پروتکل اجازه می‌دهند cipher داخل تونل را انتخاب کنید (روی **هر دو** سرور باید مقدار
**یکسان** انتخاب شود):

- **Shadowsocks** — کلاسیک (AEAD): `aes-256-gcm`، `aes-128-gcm`،
  `chacha20-ietf-poly1305`، `xchacha20-ietf-poly1305`؛ و Shadowsocks-2022:
  `2022-blake3-aes-256-gcm`، `2022-blake3-aes-128-gcm`،
  `2022-blake3-chacha20-poly1305`. متدهای ۲۰۲۲ به کلید base64 با طول دقیق نیاز دارند که
  نصب‌کننده به‌صورت خودکار برایتان می‌سازد.
- **VMESS** — رمزنگاری (`security`): `auto`، `aes-128-gcm`، `chacha20-poly1305`،
  `none`، `zero`.

### Security، Transmission و REALITY

برای **VLESS / VMESS / Trojan** می‌توانید لایهٔ انتقال و امنیت را هم انتخاب کنید (باز هم
روی **هر دو** سرور مقدار **یکسان**):

- **Transmission (network):** `tcp`، `ws`، `grpc`، `http` (HTTP/2)، `httpupgrade`
  (به‌همراه زیرتنظیمات مربوطه: `path` / `host` / `serviceName`).
- **Security:** `none`، `tls` یا `reality`.
  - **REALITY** — نصب‌کننده روی سرور خارج `xray x25519` را اجرا می‌کند تا جفت‌کلید و یک
    `shortId` تصادفی بسازد، و `dest` / `serverName` استتار را می‌پرسد (پیش‌فرض
    `dl.google.com`). سپس **کلید عمومی**، **shortId** و **SNI** را چاپ می‌کند تا در
    سرور ایران وارد کنید. خروجی خام دستور هم نمایش داده می‌شود تا در صورت نیاز دستی کپی کنید. پیش از ساخت کانفیگ، همان باینری pin‌شدهٔ Xray با `xray tls ping`، IP resolveشدهٔ target و handshake نوع TLS 1.3 را بررسی می‌کند. این فرمان ASN را اثبات نمی‌کند؛ برای استتار قوی‌تر، target را دستی از همان ASN سرور خارج انتخاب کنید.
  - **TLS** — گواهی واقعی Let's Encrypt یا self-signed خودکار. برای دامنهٔ واقعی `rejectUnknownSni` فعال می‌شود؛ TLS خودامضا با وجود pin برای ضد-DPI توصیه نمی‌شود.
- **VLESS Encryption** (فقط VLESS) — رمزنگاری پساکوانتومی ML-KEM با `xray vlessenc`؛ رشتهٔ
  `decryption` روی سرور خارج و رشتهٔ `encryption` چاپ‌شده روی سرور ایران قرار می‌گیرد.

گاردریل‌ها: `xtls-rprx-vision` فقط برای VLESS روی `tcp` با `tls`/`reality` تنظیم می‌شود و با VLESS Encryption ترکیب نمی‌شود. REALITY روی `ws` یا `httpupgrade` به‌دلیل ناسازگاری Xray رد می‌شود؛ `grpc` / `http` با Security برابر `none` هشدار می‌گیرند.

\* UDP در Shadowsocks/SOCKS فقط با `security: none` فعال است و زیر TLS/REALITY برای جلوگیری از نشت UDP بدون استتار غیرفعال می‌شود.

### بهینه‌سازی سرعت آپلود

فورواردر مستقیم پیش‌فرض مسیر مشترک `iptables → TUN → tun2socks → SOCKS` را حذف می‌کند و هر stream پذیرفته‌شده را مستقیم به Xray می‌دهد. در نتیجه پردازش TCP در userspace، کپی داده و context switch کمتر می‌شود؛ این موضوع به‌خصوص روی سرور ۱ vCPU مهم است. اگر کرنل BBR داشته باشد، Xray آن را فقط برای socket خروجی تونل انتخاب می‌کند و congestion control سراسری سیستم تغییر نمی‌کند.

حالت fallback یعنی `tun-legacy` همان receive window چهارمگابایتی tun2socks، TCP auto-tuning و صف بزرگ‌تر TUN را نگه می‌دارد.

هر کلاینت محلی Hysteria از پروفایل BBR حالت `aggressive` استفاده می‌کند و bandwidth limit صریح ندارد. اگر روی مسیر بسیار ناپایدار نتیجه بدتر شد، آن location را از `wild` → Edit configuration → Manage Locations بازپیکربندی و پروفایل را روی `standard` یا `conservative` بگذارید.

پروتکل `SOCKS` بدون رمزنگاری است و `Hysteria2` (هستهٔ جدا) به TLS + اوبفوسکیشن Salamander
متکی است.

---

## مدیریت سرویس

بعد از نصب، دستور `wild` از هر جای سرور در دسترس است. کافی است اجرا کنید:

```bash
wild
```

یک منوی مدیریتی باز می‌شود:

```
1) Status
2) Restart (manual)
3) Stop
4) Start
5) Live logs
6) Show config
7) Edit configuration
8) Schedule auto-restart (cron)
9) Remove scheduled restart
10) Uninstall
11) Back to main menu
```

گزینهٔ **۷** تنظیمات ذخیره‌شده را ویرایش و کانفیگ معتبر را دوباره تولید می‌کند. گزینهٔ **۸** زمان‌بندی برچسب‌دار cron را می‌سازد و گزینهٔ **۹** فقط همان ورودی را حذف می‌کند.

برای انتقال نصب ساخته‌شده با نسخهٔ قدیمی به مسیر سریع‌تر، اسکریپت جدید را یک‌بار اجرا کنید و سپس از `wild` → **Edit configuration** → **Forwarding Mode** حالت `direct` را انتخاب و Apply کنید. نصب قدیمی برای جلوگیری از تغییر ناگهانی تا این انتخاب صریح روی `tun-legacy` می‌ماند.

یا مستقیم از systemd استفاده کنید:

```bash
systemctl status wild-tunnel      # بررسی وضعیت
systemctl restart wild-tunnel     # ری‌استارت
journalctl -u wild-tunnel -f      # مشاهدهٔ زندهٔ لاگ‌ها
systemctl status 'wild-hysteria-client@*'  # کلاینت‌های locationهای Hysteria
```

پیکربندی در مسیر `/etc/wild-tunnel/` قرار دارد:

- پروتکل‌های Xray → فایل `config.json`
- گیرندهٔ Hysteria2 در سرور خارج → فایل `config.yaml`
- دیتابیس locationهای محلی → فایل `locations.json`
- کلاینت‌های Hysteria2 هر location → فایل‌های `locations/loc-N.yaml`
- وضعیت قابل‌ویرایش نصب → فایل `wild.conf`

این فایل‌ها به‌صورت atomic و با mode برابر `0600` نوشته می‌شوند. JSON با `jq` parse و پیش از restart به‌صورت معنایی توسط Xray تست می‌شود؛ YAML نیز با PyYAML parse می‌شود.

هنگام استفاده از گواهی واقعی، یک **deploy hook** در مسیر
`/etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh` بعد از هر تمدید خودکار، سرویس را
ری‌استارت می‌کند تا تونل هیچ‌وقت گواهی منقضی سرو نکند.

---

## حذف نصب

گزینهٔ Uninstall را انتخاب کنید (پیش از نصب گزینهٔ **۳** و پس از نصب از منوی مدیریت). هر دو سرویس متوقف، sysctlها بازیابی و قوانین محدود فایروال، باینری‌ها، فرمان مدیریت، کانفیگ، cron و hook تمدید حذف می‌شوند.
گواهی‌های Let's Encrypt در مسیر `/etc/letsencrypt` دست‌نخورده باقی می‌مانند.

---

## نکات امنیتی

- همهٔ پروتکل‌های Xray (`VLESS`، `VMESS`، `Trojan`، `Shadowsocks`، `SOCKS`) می‌توانند
  لایهٔ **Transmission** (tcp/ws/grpc/http/httpupgrade) و **Security**
  (`none`/`tls`/`reality`) بگیرند.
- با `security: none` تونل به‌راحتی شناسایی می‌شود. زیر DPI ایران، اتصال برقرار
  می‌شود و آپلود هم عبور می‌کند، اما **اولین بستهٔ دادهٔ برگشتی دراپ می‌شود** و تونل
  انگار هنگ می‌کند. این باگ نیست: افزودن **REALITY** به همان پروتکل و همان پورت
  مشکل را حل می‌کند. توصیه: از **REALITY** استفاده کنید.
- `Shadowsocks` و `SOCKS` وقتی tls/reality فعال باشد فقط **TCP** را فوروارد می‌کنند؛
  چون UDP آن‌ها بدون استتار از کنار لایهٔ ترنسپورت رد می‌شود (Xray بدون XUDP روی
  مسیر UDP بومی این پروتکل‌ها streamSettings اعمال نمی‌کند).
- گواهی self-signed از `CN=bing.com` استفاده می‌کند. Xray v26 فیلد `allowInsecure` را حذف کرده و pin در `pinnedPeerCertSha256` قرار می‌گیرد. Hysteria2 نیز با `pinSHA256` همین مدل اعتماد را دارد و `insecure` فقط همراه pin فعال می‌شود. Pin احراز هویت سرور را محافظت می‌کند، اما handshake خودامضا همچنان fingerprintپذیر است و برای ضد-DPI توصیه نمی‌شود.
- TLS دامنهٔ واقعی در Xray، SNI ناشناخته را رد می‌کند. ACL سرور Hysteria فقط sentinel فوروارد و مقصد دقیق health-check را مجاز می‌گذارد و با `reject(all)` تمام درخواست‌های دیگر را می‌بندد؛ بنابراین کاربر احرازشده نمی‌تواند تونل را به‌عنوان پراکسی عمومی استفاده کند.
- فایل‌های release مربوط به Xray، Hysteria و tun2socks به نسخه و SHA-256 ثابت pin شده‌اند و پیش از نصب atomic اعتبارسنجی می‌شوند. کانفیگ، state و کلیدهای خصوصی با `umask 077` ساخته می‌شوند.

---

## لایسنس

تحت [لایسنس MIT](LICENSE) منتشر شده است.

</div>
