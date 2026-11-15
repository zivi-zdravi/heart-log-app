# Zdravlje AI server

A tiny service that holds the Claude API key so the phones never do. Zdravlje sends it a meal description, a meal photo or a question with daily summaries; it asks Claude and sends the answer back.

- **Private:** it listens only on the server itself. Tailscale Serve gives it an HTTPS address that only devices on your tailnet can reach. No router ports, no public address.
- **Separate:** it runs in its own container with a read-only filesystem and no access to `/srv/data` or anything else on the server. Its only folder is `./data`, which holds one file: this month's request count and cost.
- **Keeps nothing:** meal text, photos, questions and health summaries are never logged or written to disk.
- **Can't run up a bill:** it stops answering for the rest of the month at the monthly limit (starts at $10; an admin can change it in the app). Set a spend limit in the Claude Console too.
- **No dependencies:** one file of Node.js (`server.js`) on the official `node:22-alpine` image.

## Setup (about 15 minutes)

You need: Katie's Claude API key (she makes it at console.anthropic.com; get it from her in person or by AirDrop, not email or text).

### 1. Get the files

```bash
sudo git clone https://github.com/zivi-zdravi/heart-log-app.git /opt/zdravlje
sudo chown -R $USER:$USER /opt/zdravlje
cd /opt/zdravlje/server
```

### 2. Settings

```bash
cp .env.example .env
chmod 600 .env
openssl rand -hex 16   # run twice: one pass code for Katie, one for you
nano .env
```

In `.env`, paste the Claude key after `ANTHROPIC_API_KEY=` and put the two codes in `PASSCODES` (`katie:<code>,zoran:<code>`). For Una or Darinka later, add `una:<code>` and so on, then repeat step 3.

### 3. Start it

```bash
mkdir -p data && sudo chown 1000:1000 data   # the container runs as user 1000
docker compose up -d --build
curl http://127.0.0.1:8787/health            # should print {"ok":true}
docker logs zdravlje-ai                      # should say "2 pass code(s)"
```

### 4. Turn on HTTPS names in Tailscale (once)

In the Tailscale admin console (login.tailscale.com), go to **DNS**. Make sure **MagicDNS** is on, then turn on **HTTPS Certificates**.

### 5. Give it a private HTTPS address

```bash
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8787
tailscale serve status
```

`serve status` shows the address, like `https://borisavljevicserver.tail1234.ts.net:8443`. Port 8443 keeps it clear of anything else you serve. The setting survives reboots.

### 6. Test from a phone

With Tailscale on, open `https://<that address>/health` in Safari. It should show `{"ok":true}`.

### 7. Set up the phones

In Zdravlje: **Settings, AI**. Enter the address (without `/health`) and that person's pass code, then tap **Check connection**. It should say "Working, as katie".

## Everyday

- **Update:** `cd /opt/zdravlje && git pull && cd server && docker compose up -d --build`
- **Turn off one phone:** delete that person's entry from `PASSCODES` in `.env`, then `docker compose up -d`.
- **New Claude key:** edit `.env`, then `docker compose up -d`.
- **See usage:** `cat /opt/zdravlje/server/data/usage.json`
- **Backups (optional):** add `/opt/zdravlje/server/.env` and `/opt/zdravlje/server/data` to `nightly-backup.sh`. The `.env` holds the Claude key, so keep that backup drive private.
- **Stop it:** `docker compose down` (and `sudo tailscale serve --https=8443 off` to remove the address).

## Models and cost

Meal descriptions use Claude Haiku 5.5; photos and questions use Claude Sonnet 5.5. Change them with `MODEL_TEXT`, `MODEL_PHOTO` and `MODEL_ASK` in `.env`. A described meal costs well under a cent; a photo or a question about a week or month of data about a cent; a question about a whole year about 10 cents.

## Test

`node test.js` runs the server against a stand-in for Claude (no key or network needed).
