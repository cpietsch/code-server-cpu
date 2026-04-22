# Devbox — Dev Container für Coolify

Ein per Tailscale erreichbarer Dev-Container auf deinem Coolify-Host, mit Python, Node, Docker-CLI (gegen Host-Socket), SSH-Server für Cursor/VS Code Remote, und allem Kleinkram (git, gh, uv, pnpm, ripgrep, zsh, tmux).

## Architektur

```
Laptop ──tailnet──► tailscale container ◄── shared netns ──► dev container (sshd)
                     (NET_ADMIN, tun)                              │
                                                                   │ TCP+TLS
                                                                   ▼  localhost:2376
                                                             dind container
                                                             (privileged, isoliert)
                                                                   │
                                                             devbox-dind-data
                                                             (eigene Images/Container)
```

Wichtige Entscheidungen:

- **Kein Port-Publishing am Host.** Der SSH-Port ist nur übers Tailnet erreichbar. Keine Angriffsfläche auf der öffentlichen IP.
- **Tailscale als Sidecar**, nicht im Dev-Image. Sauberer Lifecycle (Tailscale-Update ≠ Image-Rebuild), und der Dev-Container braucht keine NET_ADMIN-Caps.
- **Docker-in-Docker als Sidecar.** Eigener, isolierter Daemon. Der Dev-Container redet per TCP+TLS (localhost:2376 dank shared netns) mit dem Daemon und hat *keinen* Zugriff auf den Host-Docker oder Coolify. Preis: der `dind`-Container läuft mit `privileged: true`, aber dieses Privileg bleibt in seinem eigenen Namespace. Saubere Trennung vom Coolify-Docker auf dem Host.
- **Claude Code wird nicht ins Image gebacken.** Installation nach dem ersten Login per `npm i -g @anthropic-ai/claude-code`. Updates sind dann ein `npm update -g` statt Image-Rebuild.

## Deployment in Coolify

1. Lege ein Git-Repo mit `Dockerfile`, `sshd_dev.conf`, `entrypoint.sh`, `docker-compose.yml` an (genau diese Dateien aus diesem Ordner).
2. In Coolify: **Project → + New Resource → Docker Compose Empty** (oder "Application" → "Docker Compose" wenn du aus Git baust).
3. Compose-File einfügen bzw. Git-Repo verbinden.
4. **Environment Variables** in der Coolify-UI setzen:

   | Variable | Beispiel / Hinweis |
   |---|---|
   | `TS_AUTHKEY` | `tskey-auth-...` aus https://login.tailscale.com/admin/settings/keys. Empfohlen: *Reusable + Ephemeral* NICHT setzen (du willst den Host behalten), *Pre-approved* wenn du Device-Approval nutzt. |
   | `TS_HOSTNAME` | `devbox` (oder was auch immer im Tailnet auftauchen soll) |
   | `SSH_AUTHORIZED_KEYS` | Deine Public Keys, eine pro Zeile. Inhalt von `~/.ssh/id_ed25519.pub` |

5. Deploy. Beim ersten Start baut Coolify das Image, beide Container gehen hoch, Tailscale registriert sich.

## Ersteinrichtung nach dem ersten Deploy

### Tailnet-Hostname finden

In deinem [Tailscale Admin-Panel](https://login.tailscale.com/admin/machines) taucht jetzt ein Gerät namens `devbox` auf. Notiere dir den MagicDNS-Namen (z. B. `devbox.tail-scales.ts.net`).

### SSH-Verbindung testen

Auf deinem Laptop (Tailscale muss auch da laufen):

```bash
ssh dev@devbox           # MagicDNS reicht, wenn aktiviert
# oder
ssh dev@devbox.<tailnet>.ts.net
```

Beim ersten Verbinden bestätigst du den Host-Key (der wird im Volume `devbox-sshhostkeys` persistiert, also bleibt er über Rebuilds stabil).

### `~/.ssh/config` auf dem Laptop

```ssh-config
Host devbox
    HostName devbox.<tailnet>.ts.net
    User dev
    ForwardAgent yes
    ServerAliveInterval 30
```

Danach reicht in Cursor/VS Code: **Remote-SSH: Connect to Host... → devbox**.

### Claude Code installieren

Nach dem SSH-Login:

```bash
npm i -g @anthropic-ai/claude-code
claude --version
claude   # Erstlogin mit deinem Anthropic-Account
```

Authentifizierung läuft interaktiv über OAuth-Flow im Browser; da du SSH benutzt, druckt `claude` eine URL, die du am Laptop öffnest.

### Workspace

Dein Code gehört nach `/home/dev/workspace` — das ist ein eigenes Docker-Volume, überlebt also Rebuilds und Updates. Beispiel:

```bash
cd ~/workspace
gh auth login          # einmalig
gh repo clone me/projekt
cd projekt
uv venv && source .venv/bin/activate    # für Python
pnpm install                             # für Node
```

## Docker-Zugriff

Der Dev-Container redet mit dem DinD-Daemon — **nicht** mit dem Coolify-Host. Das ist eine saubere Trennung: Container, die du hier startest, sind für Coolify unsichtbar und können dein Produktionssetup nicht versehentlich zerlegen.

```bash
docker info        # zeigt den dind-Daemon, nicht den Host
docker ps          # nur Container, die DU in dind gestartet hast
docker run --rm hello-world
```

Die Client-Zertifikate für den TLS-Handshake liegen in `/certs/client/` (read-only gemountet). `DOCKER_HOST`, `DOCKER_TLS_VERIFY` und `DOCKER_CERT_PATH` werden automatisch in interaktive Shells exportiert — du musst nichts konfigurieren.

**Wo liegen meine Images?** Im Volume `devbox-dind-data`. Überlebt Rebuilds des Dev-Containers, überlebt Neustarts. Weg nur, wenn du das Volume explizit löschst.

**Wenn du den Host-Docker brauchst** (z. B. um einen Coolify-Container-Log zu tailen): einfach `docker -H unix:///var/run/docker.sock …`, das geht aber nicht — weil wir den Socket bewusst nicht mehr mounten. Für solche Fälle `ssh` auf den Host selbst oder über die Coolify-UI.

## Ressourcen

Der Dev-Container selbst ist schlank (~1–2 GB RAM im Idle, CPU nur unter Last). Auf deinen 12 GB / 6 Kernen bleibt genug für Coolify und Deployments übrig. Wenn du willst, kannst du in der Compose-Datei unter dem `dev`-Service Limits setzen:

```yaml
    deploy:
      resources:
        limits:
          cpus: "4"
          memory: 8g
```

## Updates

- **Node/Python/Tools updaten**: Image neu bauen lassen in Coolify (Redeploy). Deine Workspace- und Home-Volumes bleiben erhalten.
- **Tailscale updaten**: Nur den `tailscale`-Service redeployen, Dev-Container bleibt live.
- **Claude Code updaten**: `npm update -g @anthropic-ai/claude-code` im SSH-Session.

## Troubleshooting

- **SSH geht nicht**: Prüfe in Coolify Logs des `dev`-Services, ob `sshd` läuft. Prüfe im `tailscale`-Service, ob die Anmeldung geklappt hat (`tailscale status`).
- **`docker: Cannot connect to the Docker daemon`**: DinD ist noch nicht fertig hochgefahren oder die Certs wurden noch nicht geschrieben. `docker compose logs dind` in Coolify prüfen. Nach einem Reboot dauert es ein paar Sekunden, bis der Daemon bereit ist.
- **`docker: tls: failed to verify certificate`**: Das Cert-Volume (`devbox-dind-certs`) wurde manuell geleert oder ist zwischen dind- und dev-Container inkonsistent. Beide Container neu starten, damit dind frische Certs erzeugt, die der Dev-Container dann sieht.
- **Host-Key-Warnung auf dem Laptop nach Rebuild**: Sollte mit dem Host-Key-Volume nicht passieren. Falls doch: `ssh-keygen -R devbox` auf dem Laptop, einmal neu verbinden.
- **Tailscale-Container restartet endlos**: meistens abgelaufener/ungültiger `TS_AUTHKEY`. Neuen Key erzeugen, Env-Var aktualisieren, redeploy.
- **DinD-Volume zu groß**: `docker system prune -a` im Dev-Container räumt auf, wirkt auf den DinD-Daemon und lässt den Host-Docker unberührt.
