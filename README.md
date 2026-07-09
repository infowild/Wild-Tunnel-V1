# Wild Tunnel v1

**English** | [فارسی](#wild-tunnel-v1-فارسی)

A single-file installer for a **two-server tunnel** designed to forward ports from a
local server (e.g. inside Iran) to a remote server abroad. It supports multiple
transport protocols powered by two cores:

- **Xray-core** — `VLESS`, `VMESS`, `Trojan`, `Shadowsocks`, `SOCKS`
- **Hysteria2** (`apernet/hysteria`) — native UDP transport with Salamander obfuscation

Both TCP and UDP traffic on the selected ports are relayed through the tunnel.

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
   (dokodemo-door / port-forwarding)           on its own side
```

- **Remote server (Receiver):** terminates the tunnel and forwards traffic to
  `127.0.0.1:<port>` on itself (via Xray `freedom` outbound, or Hysteria2's built-in
  proxy). This is where your panel/service actually listens.
- **Local server (Forwarder):** opens the chosen ports and pushes everything that
  arrives into the tunnel. For Xray this uses `dokodemo-door` inbounds; for Hysteria2
  it uses native `tcpForwarding` / `udpForwarding`.

The service runs as a single systemd unit named `wild-tunnel`. The unit file is
generated at install time based on the selected core and role, so the installer does
not depend on being run from any particular directory.

---

## Requirements

- Ubuntu / Debian with `systemd`
- `root` access (run with `sudo` or as root)
- Two servers (one abroad, one local)
- For a **real** TLS certificate: a domain pointing at the remote server and TCP
  port **80** free (Let's Encrypt standalone challenge)

Before doing anything else, the installer updates the package lists and installs
all prerequisites it needs (`unzip`, `jq`, `openssl`, `uuid-runtime`, `wget`,
`curl`, `iproute2`, `cron`, and `certbot` on demand).

**No conflict with the Sanaei / 3x-ui panel.** Everything is namespaced
(`wild-tunnel` service, `/usr/local/bin/wild-xray`, `/etc/wild-tunnel`, `wild`
command), so it never touches the panel's `x-ui` service, `/usr/local/x-ui`,
`/etc/x-ui` or `/usr/bin/x-ui`. The only possible clash is a port already used by
the panel (default `2053`) or another service — the installer checks with `ss` and
warns before binding.

---

## Installation

### Easy install (one-liner)

Run this on **each** server (as root) and follow the prompts:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/Wild-Tunnel-V1/main/install.sh)
```

> Use `bash <(curl ...)`, **not** `curl ... | bash` — the installer is interactive
> and piping would break its prompts. If `curl` is missing:
> `apt-get update && apt-get install -y curl`.

### Manual install

Alternatively, clone the repository and run the installer:

```bash
git clone https://github.com/infowild/Wild-Tunnel-V1.git wild-tunnel
cd wild-tunnel
chmod +x install.sh
sudo ./install.sh
```

You will be asked to choose a role:

```
1) Install Remote Server (Foreign - Receiver)
2) Install Local Server (Iran - Forwarder)
3) Uninstall Wild Tunnel
```

### 1. Set up the Remote server first

Choose option **1**, then:

1. Enter the **Tunnel Port** (default `50000`).
2. Pick a **protocol** (1–6).
3. Provide/auto-generate the credentials (UUID or password, plus obfuscation
   password for Hysteria2).
4. For `Trojan` / `Hysteria2`, choose between a **real Let's Encrypt certificate**
   (needs a domain) or an auto-generated **self-signed** certificate.

At the end the installer prints all the details (port, protocol, UUID/password,
obfuscation password, SNI). **Save them** — you need them for the local server.

### 2. Set up the Local server

Choose option **2**, then:

1. Enter the **Remote Server IP**.
2. Enter the **same Tunnel Port** and **same protocol/credentials** as the remote.
3. Enter the **ports to tunnel** (comma-separated, e.g. `2053,8443`).
4. For `Trojan` / `Hysteria2`, state whether the remote uses a real domain (for the
   correct SNI / certificate validation).

Once finished, connecting to `LOCAL_IP:<port>` reaches `127.0.0.1:<port>` on the
remote server through the tunnel.

---

## Protocols

| # | Protocol     | Core       | Transport | TLS                         |
|---|--------------|------------|-----------|-----------------------------|
| 1 | VLESS        | Xray-core  | TCP       | none                        |
| 2 | VMESS        | Xray-core  | TCP       | none                        |
| 3 | Trojan       | Xray-core  | TCP       | TLS (real or self-signed)   |
| 4 | Shadowsocks  | Xray-core  | TCP/UDP   | built-in (selectable cipher)|
| 5 | SOCKS        | Xray-core  | TCP/UDP   | none                        |
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
    (default `www.microsoft.com`). It prints the **public key**, **shortId** and
    **SNI** to enter on the local server. The raw generator output is also shown so
    you can copy values manually if needed.
  - **TLS** — real Let's Encrypt certificate or an auto self-signed one.
- **VLESS Encryption** (VLESS only) — post-quantum ML-KEM encryption via
  `xray vlessenc`; the `decryption` string goes on the remote and the printed
  `encryption` string on the local server.

Guardrails: `xtls-rprx-vision` flow is only applied to VLESS over `tcp` with
`tls`/`reality`, and is never combined with VLESS Encryption; `grpc` / `http`
transports warn if you pick `none` security.

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
7) Schedule auto-restart (cron)
8) Remove scheduled restart
9) Uninstall
```

Option **7** installs a `crontab` entry that restarts the tunnel on a schedule
(every 6h / 12h / daily, or a custom cron expression); option **8** removes it.

Or use systemd directly:

```bash
systemctl status wild-tunnel      # check status
systemctl restart wild-tunnel     # restart
journalctl -u wild-tunnel -f      # follow logs
```

Configuration lives in `/etc/wild-tunnel/`:

- Xray protocols → `config.json`
- Hysteria2 → `config.yaml`

When a real certificate is used, a Let's Encrypt **deploy hook** at
`/etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh` restarts the service after
each automatic renewal, so the tunnel never serves an expired certificate.

---

## Uninstall

Run the installer and choose option **3**, which stops and removes the service, the
core binaries (`/usr/local/bin/wild-xray`), the configuration (`/etc/wild-tunnel`),
and the renewal hook. Let's Encrypt certificates under `/etc/letsencrypt` are left
untouched.

---

## Security notes

- `VLESS`, `VMESS`, and `SOCKS` are tunneled **without TLS** (`security: none`). They
  are fast but more easily fingerprinted. For obfuscation-resistant setups prefer
  **Trojan** (TLS) or **Hysteria2** (TLS + Salamander).
- Self-signed certificates use `CN=bing.com` and the client sets `allowInsecure`.
  Use a real domain + Let's Encrypt when you need genuine certificate validation.

---

## License

Released under the [MIT License](LICENSE).

---
---

<div dir="rtl">

# Wild Tunnel v1 (فارسی)

[English](#wild-tunnel-v1) | **فارسی**

یک نصب‌کنندهٔ تک‌فایلی برای ساخت یک **تونل دوسروری** که پورت‌ها را از یک سرور محلی
(مثلاً داخل ایران) به یک سرور خارج منتقل می‌کند. از چند پروتکل با دو هستهٔ مختلف
پشتیبانی می‌کند:

- **Xray-core** — پروتکل‌های `VLESS`، `VMESS`، `Trojan`، `Shadowsocks`، `SOCKS`
- **Hysteria2** (`apernet/hysteria`) — انتقال بومی روی UDP با اوبفوسکیشن Salamander

ترافیک TCP و UDP روی پورت‌های انتخاب‌شده، هر دو از داخل تونل عبور داده می‌شوند.

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
   (dokodemo-door / port-forwarding)           خودش وصل می‌شود
```

- **سرور خارج (گیرنده):** تونل را دریافت می‌کند و ترافیک را به `127.0.0.1:<port>` روی
  خودش می‌فرستد (از طریق outbound نوع `freedom` در Xray یا پروکسی داخلی Hysteria2).
  پنل/سرویس واقعی شما این‌جا گوش می‌دهد.
- **سرور محلی (فورواردر):** پورت‌های انتخابی را باز می‌کند و هر چیزی که برسد را به داخل
  تونل هدایت می‌کند. برای Xray از inbound نوع `dokodemo-door` و برای Hysteria2 از
  `tcpForwarding` / `udpForwarding` بومی استفاده می‌شود.

سرویس به‌صورت یک یونیت واحد systemd با نام `wild-tunnel` اجرا می‌شود. فایل یونیت هنگام
نصب و بر اساس هسته و نقش انتخابی ساخته می‌شود، بنابراین اجرای نصب‌کننده به هیچ مسیر
خاصی وابسته نیست.

---

## پیش‌نیازها

- اوبونتو / دبیان با `systemd`
- دسترسی `root` (با `sudo` یا کاربر root اجرا کنید)
- دو سرور (یکی خارج، یکی محلی)
- برای گواهی TLS **واقعی**: یک دامنه که به IP سرور خارج اشاره کند و پورت TCP شمارهٔ
  **۸۰** آزاد باشد (چالش standalone در Let's Encrypt)

نصب‌کننده پیش از هر کاری، لیست پکیج‌ها را آپدیت و همهٔ پیش‌نیازهای موردنیازش را نصب
می‌کند (`unzip`، `jq`، `openssl`، `uuid-runtime`، `wget`، `curl`، `iproute2`، `cron` و
در صورت نیاز `certbot`).

**بدون تداخل با پنل سنایی / 3x-ui.** همه‌چیز در namespace جدا است (سرویس
`wild-tunnel`، مسیر `/usr/local/bin/wild-xray`، کانفیگ `/etc/wild-tunnel`، دستور
`wild`)، پس هرگز به سرویس `x-ui` پنل و مسیرهای `/usr/local/x-ui`، `/etc/x-ui` و
`/usr/bin/x-ui` دست نمی‌زند. تنها تداخل ممکن، پورتی است که پنل (پیش‌فرض `2053`) یا سرویس
دیگری از آن استفاده کند — نصب‌کننده با `ss` بررسی و پیش از bind هشدار می‌دهد.

---

## نصب

### نصب آسان (تک‌خطی)

این دستور را روی **هر دو** سرور (با کاربر root) اجرا کنید و به سؤال‌ها پاسخ دهید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/infowild/Wild-Tunnel-V1/main/install.sh)
```

> از فرم `bash <(curl ...)` استفاده کنید، **نه** `curl ... | bash` — چون نصب‌کننده
> تعاملی است و حالت pipe سؤال‌ها را خراب می‌کند. اگر `curl` نصب نبود:
> `apt-get update && apt-get install -y curl`.

### نصب دستی

به‌جای آن می‌توانید مخزن را کلون کنید و نصب‌کننده را اجرا کنید:

```bash
git clone https://github.com/infowild/Wild-Tunnel-V1.git wild-tunnel
cd wild-tunnel
chmod +x install.sh
sudo ./install.sh
```

از شما خواسته می‌شود یک نقش انتخاب کنید:

```
1) Install Remote Server (Foreign - Receiver)
2) Install Local Server (Iran - Forwarder)
3) Uninstall Wild Tunnel
```

### ۱. ابتدا سرور خارج را راه‌اندازی کنید

گزینهٔ **۱** را انتخاب کنید، سپس:

1. **پورت تونل** را وارد کنید (پیش‌فرض `50000`).
2. یک **پروتکل** انتخاب کنید (۱ تا ۶).
3. اطلاعات ورود را وارد یا به‌صورت خودکار بسازید (UUID یا پسورد، و برای Hysteria2
   پسورد اوبفوسکیشن).
4. برای `Trojan` / `Hysteria2` بین **گواهی واقعی Let's Encrypt** (نیازمند دامنه) یا
   گواهی **self-signed** خودساخته انتخاب کنید.

در پایان، نصب‌کننده تمام جزئیات (پورت، پروتکل، UUID/پسورد، پسورد اوبفوسکیشن، SNI) را چاپ
می‌کند. **آن‌ها را ذخیره کنید** — برای سرور محلی لازم‌شان دارید.

### ۲. سرور محلی را راه‌اندازی کنید

گزینهٔ **۲** را انتخاب کنید، سپس:

1. **IP سرور خارج** را وارد کنید.
2. **همان پورت تونل** و **همان پروتکل/اطلاعات ورود** سرور خارج را وارد کنید.
3. **پورت‌هایی که می‌خواهید تونل شوند** را وارد کنید (با کاما جدا شوند، مثلاً `2053,8443`).
4. برای `Trojan` / `Hysteria2` مشخص کنید که آیا سرور خارج از دامنهٔ واقعی استفاده می‌کند
   (برای SNI / اعتبارسنجی گواهی درست).

پس از پایان، اتصال به `LOCAL_IP:<port>` از طریق تونل به `127.0.0.1:<port>` روی سرور خارج
می‌رسد.

---

## پروتکل‌ها

| # | پروتکل       | هسته       | انتقال    | TLS                          |
|---|--------------|------------|-----------|------------------------------|
| ۱ | VLESS        | Xray-core  | TCP       | ندارد                        |
| ۲ | VMESS        | Xray-core  | TCP       | ندارد                        |
| ۳ | Trojan       | Xray-core  | TCP       | TLS (واقعی یا self-signed)    |
| ۴ | Shadowsocks  | Xray-core  | TCP/UDP   | داخلی (cipher قابل انتخاب)     |
| ۵ | SOCKS        | Xray-core  | TCP/UDP   | ندارد                        |
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
    `www.microsoft.com`). سپس **کلید عمومی**، **shortId** و **SNI** را چاپ می‌کند تا در
    سرور ایران وارد کنید. خروجی خام دستور هم نمایش داده می‌شود تا در صورت نیاز دستی کپی کنید.
  - **TLS** — گواهی واقعی Let's Encrypt یا self-signed خودکار.
- **VLESS Encryption** (فقط VLESS) — رمزنگاری پساکوانتومی ML-KEM با `xray vlessenc`؛ رشتهٔ
  `decryption` روی سرور خارج و رشتهٔ `encryption` چاپ‌شده روی سرور ایران قرار می‌گیرد.

گاردریل‌ها: flow با نام `xtls-rprx-vision` فقط برای VLESS روی `tcp` با `tls`/`reality` ست
می‌شود و هرگز با VLESS Encryption ترکیب نمی‌شود؛ انتقال‌های `grpc` / `http` اگر Security را
`none` بگذارید هشدار می‌دهند.

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
7) Schedule auto-restart (cron)
8) Remove scheduled restart
9) Uninstall
```

گزینهٔ **۷** یک ورودی `crontab` می‌سازد که تونل را طبق زمان‌بندی ری‌استارت می‌کند (هر ۶ یا
۱۲ ساعت / روزانه، یا عبارت cron دلخواه)؛ گزینهٔ **۸** آن را حذف می‌کند.

یا مستقیم از systemd استفاده کنید:

```bash
systemctl status wild-tunnel      # بررسی وضعیت
systemctl restart wild-tunnel     # ری‌استارت
journalctl -u wild-tunnel -f      # مشاهدهٔ زندهٔ لاگ‌ها
```

پیکربندی در مسیر `/etc/wild-tunnel/` قرار دارد:

- پروتکل‌های Xray → فایل `config.json`
- Hysteria2 → فایل `config.yaml`

هنگام استفاده از گواهی واقعی، یک **deploy hook** در مسیر
`/etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh` بعد از هر تمدید خودکار، سرویس را
ری‌استارت می‌کند تا تونل هیچ‌وقت گواهی منقضی سرو نکند.

---

## حذف نصب

نصب‌کننده را اجرا کنید و گزینهٔ **۳** را انتخاب کنید؛ سرویس، باینری‌های هسته
(`/usr/local/bin/wild-xray`)، پیکربندی (`/etc/wild-tunnel`) و hook تمدید حذف می‌شوند.
گواهی‌های Let's Encrypt در مسیر `/etc/letsencrypt` دست‌نخورده باقی می‌مانند.

---

## نکات امنیتی

- پروتکل‌های `VLESS`، `VMESS` و `SOCKS` **بدون TLS** تونل می‌شوند (`security: none`).
  سریع هستند اما راحت‌تر شناسایی می‌شوند. برای مقاومت در برابر شناسایی، **Trojan** (با
  TLS) یا **Hysteria2** (TLS + Salamander) را ترجیح دهید.
- گواهی‌های self-signed از `CN=bing.com` استفاده می‌کنند و کلاینت `allowInsecure` را
  فعال می‌کند. برای اعتبارسنجی واقعی گواهی، از دامنهٔ واقعی + Let's Encrypt استفاده کنید.

---

## لایسنس

تحت [لایسنس MIT](LICENSE) منتشر شده است.

</div>
