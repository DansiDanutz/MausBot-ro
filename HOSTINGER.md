# MausBot on Hostinger

This repository is [OpenMausBot](https://github.com/milind-soni/OpenMausBot)
(Apache-2.0) at **v0.1.169**, with a Hostinger deployment layer in
[`deploy/hostinger/`](deploy/hostinger/README.md). The app is unchanged; the
deployment layer adds a one-command install, engine keys and bot provisioning.

## Quick start

You need a **Hostinger KVM 2** VPS (or larger) with **Ubuntu 24.04**, a domain
whose A record points at the VPS, and hPanel's firewall open on 22, 80 and 443.
Web Hosting, Cloud Hosting and KVM 1 are not enough. The full runbook, with
hPanel steps in prose and troubleshooting, is in
[`deploy/hostinger/README.md`](deploy/hostinger/README.md).

```sh
ssh root@YOUR_VPS_IP

curl -fsSL https://raw.githubusercontent.com/DansiDanutz/MausBot-ro/main/deploy/hostinger/install.sh \
  | sh -s -- --domain maus.example.com
```

That installs Docker if needed, runs the project's own
[`deploy/install.sh`](deploy/install.sh) (checks, containers, Caddy, HTTPS,
bot sandbox), applies engine keys from `/etc/mausbot/hostinger.env` if present,
and creates one bot per engine that is ready. It ends with the URL and a
one-time admin sign-in link (also saved root-only to
`/root/mausbot-pairing.txt`).

Check the server without changing it:

```sh
curl -fsSL https://raw.githubusercontent.com/DansiDanutz/MausBot-ro/main/deploy/hostinger/install.sh \
  | sh -s -- --check --domain maus.example.com
```

## Engines and bots

- **API keys** — fill [`hostinger.env.example`](deploy/hostinger/hostinger.env.example),
  then run the installer with `--bots-only`.
- **Subscriptions** — sign Claude Code, Codex and Grok in once on the server
  (`docker compose exec omb …`), then `--bots-only`.

Both routes, and how to add bots later, are in the
[Hostinger runbook](deploy/hostinger/README.md#4-engines-and-bots).

## Day two

```sh
cd /opt/openmausbot
sudo docker compose logs -f omb
sudo ./update.sh
```

Data lives in `/opt/openmausbot/data`; back that folder up. Settings and the
pinned image version are in `/opt/openmausbot/.env`.

## Keeping up with upstream

`main` is the upstream tree, commit for commit; the Hostinger layer is a small
addition on top. To move to a newer release:

```sh
git fetch upstream main
git merge upstream/main      # or reset a deployment branch onto it
```

`upstream` is `https://github.com/milind-soni/OpenMausBot.git`. The server's own
`update.sh` handles released images on the VPS without touching this checkout.
