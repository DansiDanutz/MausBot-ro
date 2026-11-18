# OpenMausBot on Hostinger

One command takes a fresh Hostinger KVM VPS to OpenMausBot on your own domain
with HTTPS, then gives you bots. The server, its data and every bot live on the
VPS, so they keep working with every laptop closed.

This folder is the Hostinger layer only: the server itself is the project's
[`deploy/install.sh`](../install.sh), which this wrapper runs. Everything the
upstream [VPS guide](../../docs/deploy-vps.md) says about ports, DNS, pairing and
updates applies here too.

## What plan you need

| Hostinger product | Works? | Why |
|---|---|---|
| **VPS KVM 2** or larger | Yes | 2 vCPU, 8 GB, 100 GB — the minimum the installer accepts |
| VPS KVM 1 | No | 1 vCPU and 4 GB; the bot sandbox and the engines need more |
| Web Hosting / Cloud Hosting | No | no Docker, no root, no long-running containers |
| Horizons | No | it builds websites, not servers |

Pick **Ubuntu 24.04** in the VPS order form. The installer refuses 20.04 and
non-x86 images, and adds Docker itself if the template has none.

You also need a domain name. A subdomain is enough (`maus.example.com`), and it
can be registered anywhere; Hostinger's own DNS works.

## 1. Create the VPS

1. hPanel → **VPS** → **Create VPS**.
2. Plan **KVM 2** (or larger), location closest to you.
3. OS: **Ubuntu 24.04** (the plain template; the Docker template works too).
4. Add your SSH public key, or set a root password. Hostinger emails the root
   password when neither is set.
5. Create it, then copy the **IPv4 address** from the VPS overview.

In hPanel → VPS → **Firewall**, allow **22**, **80** and **443**. Hostinger's
firewall is in front of the machine and is separate from `ufw`; the installer
opens `ufw` if it is active, but it cannot change hPanel's.

## 2. Point the domain at the VPS

At your DNS provider, add an **A** record:

| Type | Name | Value | TTL |
|---|---|---|---|
| A | `maus` | your VPS IPv4 | 300 |

With the domain at Hostinger: hPanel → **Domains** → your domain → **DNS / Nameservers**
→ **DNS Zone Editor** → add the record.

Check it before installing — the installer stops if the name does not resolve to
this server:

```sh
dig +short maus.example.com
```

## 3. Install

SSH in and run the one command. It checks the machine, installs Docker if it is
missing (Docker's official `get.docker.com` script), runs the OpenMausBot
installer, then sets any engine keys and makes the bots:

```sh
ssh root@YOUR_VPS_IP

curl -fsSL https://raw.githubusercontent.com/DansiDanutz/MausBot-ro/main/deploy/hostinger/install.sh \
  | sh -s -- --domain maus.example.com
```

From a checkout, the same thing:

```sh
sudo sh deploy/hostinger/install.sh --domain maus.example.com
```

| Flag | Effect |
|---|---|
| `--domain HOST` | required; the name people open |
| `--email you@example.com` | lets the first admin sign in with an emailed code |
| `--keys-file FILE` | engine keys to apply (default `/etc/mausbot/hostinger.env`) |
| `--no-bots` | install the server and keys, create no bots |
| `--no-sandbox` | skip the bots' sandbox; only on a server you alone use |
| `--no-install-docker` | never install Docker; fail if it is missing |
| `--check` | check the server only; changes nothing |
| `--bots-only` | skip the server install; apply keys and bots again |

The first run takes about 20 minutes, mostly image pulls and the HTTPS
certificate. It ends with:

```
MausBot is running at https://maus.example.com
```

### Sign in as the first admin

The installer makes a one-time link. When its output is a terminal it prints it;
when it is a log it saves it to `/root/mausbot-pairing.txt` with mode 600
instead. Open that link in a browser, or paste it into the desktop app under
**＋ → Connect to a server**. Anyone with the link is the admin until it is used
or expires, so read it from a terminal, not from a chat log.

Make another at any time:

```sh
cd /opt/openmausbot
sudo docker compose exec omb openmausbot pair --label "First admin"
```

## 4. Engines and bots

A bot is an agent on an engine. OpenMausBot supports three CLI engines (Claude
Code, Codex, Grok Build) and API engines (Claude, OpenAI, xAI and others). The
installer gives you a bot per engine that is ready; an engine that is not
signed in yet is simply skipped.

### Option A: API keys (no browser, fully scripted)

```sh
sudo install -d -m 700 /etc/mausbot
sudo cp deploy/hostinger/hostinger.env.example /etc/mausbot/hostinger.env
sudo nano /etc/mausbot/hostinger.env     # ANTHROPIC_API_KEY=…, OPENAI_API_KEY=…
sudo sh deploy/hostinger/install.sh --bots-only --domain maus.example.com
```

`--bots-only` applies the keys with `openmausbot engine set … --install`, then
runs [`setup-bots.mjs`](setup-bots.mjs) inside the container: one bot per ready
engine, plus an **All Bots** room. It is idempotent — run it after adding a key.

### Option B: subscription logins (Claude Code, Codex, Grok)

The published server image ships Grok Build; install Claude Code and Codex into
the app's own prefix, then sign each one in once. The login lives on the data
volume and survives updates.

```sh
cd /opt/openmausbot

sudo docker compose exec omb npm install -g --prefix /data/tools/npm \
  @anthropic-ai/claude-code @openai/codex

sudo docker compose exec omb /data/tools/npm/bin/claude     # browser or paste-code sign-in
sudo docker compose exec omb /data/tools/npm/bin/codex login
sudo docker compose exec omb grok                          # device code
sudo docker compose restart omb

curl -fsSL https://raw.githubusercontent.com/DansiDanutz/MausBot-ro/main/deploy/hostinger/install.sh \
  | sudo sh -s -- --bots-only --domain maus.example.com
```

`--bots-only` only creates what is available. If you see "No engine is ready
yet", the sign-in above did not finish.

### More bots later

In the app: **＋ → New bot**, or headless:

```sh
cd /opt/openmausbot
sudo docker compose exec omb openmausbot models          # INSTANCE/MODEL pairs
sudo docker compose exec omb openmausbot new-bot Scout --model claude/claude-sonnet-5-5
sudo docker compose exec omb openmausbot bots
```

## 5. Day two

```sh
cd /opt/openmausbot

sudo docker compose ps
sudo docker compose logs -f omb        # server
sudo docker compose logs -f caddy      # HTTPS
sudo docker compose restart omb

sudo ./update.sh                       # backed-up update, rolls back on failure
```

Your data is in `/opt/openmausbot/data` on the VPS. Back that folder up; it
holds chats, bots, engine logins and paired devices. `.env` holds your settings
and the pinned image version.

## Troubleshooting

**"This VPS has 1 CPU"** — KVM 1. Upgrade to KVM 2 in hPanel → VPS → Upgrade, or
make a KVM 2 and point DNS at it.

**"does not resolve yet" / "points at … not at this server"** — the A record is
missing, cached, or a proxy. Wait for the TTL (300 s), and on Cloudflare set the
record to **DNS only**. `OMB_INSTALL_SKIP_DNS=1` skips the check when a load
balancer forwards 80/443 here.

**HTTPS never comes up** — ports 80 and 443 must reach the VPS. Check hPanel →
VPS → Firewall and `sudo ufw status`. Caddy's reason is in
`sudo docker compose logs caddy --tail 30`.

**"Docker … not available"** — rerun without `--no-install-docker`, or install
Docker from hPanel's Docker template.

**No bots after install** — no engine is signed in yet. Do Option A or B above,
then `--bots-only`.

**Lost the admin link** — make another:
`sudo docker compose exec omb openmausbot pair`.

**Hostinger's browser terminal closes during the install** — run it inside
`tmux`/`screen`, or from your own machine over SSH; the install continues even
if the terminal dies, but you lose the output.
