# CLAUDE.md — swarm-iam-platform

Contexte technique pour Claude Code. Ce fichier décrit l'architecture, les conventions et les comportements attendus pour ce projet.

---

## Projet

Infrastructure IaC Bash/Docker Swarm déployant une plateforme IAM complète (Keycloak + PostgreSQL + Redis + Traefik) sur un NAS Synology (hostname : **BlackHole**).

**Repo GitHub :** `MGNetworking/swarm-iam-platform`
**Branches :** `main` (production) → `develop` (intégration) → `feat/*` / `fix/*` / `chore/*`

---

## Stack technique

| Service    | Version   | Rôle                                            |
| ---------- | --------- | ----------------------------------------------- |
| Traefik    | v3.1      | Reverse proxy interne (port 9080)               |
| Keycloak   | 26.0      | SSO / IAM (keycloak.backhole.ovh)               |
| PostgreSQL | 17-alpine | Base de données (port 5400, alias dns-postgres) |
| Redis      | 7-alpine  | Cache session (port 6379, 512mb max)            |

---

## Architecture réseau

- `company_network` (overlay, attachable) : communication interne DB / Cache / Keycloak
- `edge_network` (overlay, attachable) : routage Traefik → Keycloak
- TLS terminé par Nginx du NAS — Traefik fonctionne en HTTP interne uniquement

---

## Structure du projet

```
environments/homeLab/       # Stacks Docker Compose + fichiers .env
  .env                      # Variables principales (noms stacks, ports, hostnames)
  config.env                # Variables de config (logs, timeouts, noms YML, réseaux)
  traefik-stack.yml
  postgresql-stack.yml
  redis-stack.yml
  keycloak-stack.yml

scripts/                    # Scripts d'orchestration
  deploy-infra.sh           # Déploiement complet (options: --force, --no-wait)
  restart-infra.sh          # Redémarrage intelligent post-reboot NAS
  reset-infra.sh            # Réinitialisation destructive (confirmation requise)
  ensure-infra.sh           # Vérifie Docker + Swarm + réseaux overlay
  ensure-backup-dirs.sh     # Crée les répertoires de backup sur l'hôte
  wait-for-it.sh            # Attente service TCP

postgres_home/scripts/      # Scripts PostgreSQL
  backup-daily-cluster.sh   # Backup quotidien cluster (rétention 30j)
  backup-manual.sh          # Backup manuel interactif (base ou schéma)
  restore-daily-cluster.sh  # Restauration depuis backup cluster
  restore-manual-db.sh      # Restauration base complète
  restore-manual-schema.sh  # Restauration schéma spécifique

secrets/
  secrets.manifest          # Liste des secrets Docker attendus (non commités)
  check-secrets.sh          # Vérifie la présence des secrets Docker
```

---

## Secrets Docker

Créés manuellement sur le NAS, **jamais commités** :

- `pg_password` — mot de passe PostgreSQL
- `redis_password` — mot de passe Redis

---

## Logs

Chemin Synology-specific : `/volume1/development/logs`
Configurable via `LOG_DIR` dans `environments/homeLab/config.env`.

---

## Conventions de code

### Scripts Bash

- Toujours commencer par `set -euo pipefail`
- Résolution du `PROJECT_ROOT` via `SCRIPT_DIR` (portable, indépendant du cwd)
- Logging avec timestamp via fonction `log()` → fichier + stdout
- Variables d'environnement validées avec `: "${VAR:?message}"` en début de script
- Scripts **idempotents** — re-exécutables sans effets de bord

### Git / Conventional Commits

- Format obligatoire : `type(scope): description`
- Types : `feat`, `fix`, `chore`, `docs`, `ci`, `refactor`
- Exemples : `feat(keycloak): add realm export`, `fix(backup): correct retention path`
- Tout le travail se fait sur `develop` ou des branches `feat/*` / `fix/*`
- Merge vers `main` uniquement via PR

### Fichiers de config

- Fins de ligne : **LF uniquement** (défini dans `.gitattributes`)
- Encodage : UTF-8
- Pas de secrets dans les fichiers commités

---

## Environnement de développement

- OS hôte : Windows 11 + WSL2 (Ubuntu)
- Projet sur NTFS (`/mnt/d/`) → `core.filemode=false` appliqué localement
- Docker cible : NAS Synology (DSM 7.x, Docker Swarm mono-node)
- SSH GitHub configuré depuis WSL2 (clé `~/.ssh/id_ed25519`)

---

## Points d'attention

- Contexte **single-node Swarm** : pas de HA, pas de réplication multi-nœud
- Chemins Synology (`/volume1/...`) non valides en dehors du NAS
- Le NAS peut rebooter → `restart-infra.sh` gère la réinitialisation du Swarm
- `reset-infra.sh` est **destructif** : supprime toutes les stacks et données
