# CLAUDE.md — swarm-iam-platform

Contexte technique pour Claude Code. Ce fichier décrit l'architecture, les conventions et les comportements attendus pour ce projet.

---

## Projet

Infrastructure IaC Bash/Kubernetes (k3s) déployant une plateforme IAM complète
(Keycloak + PostgreSQL + Redis + Traefik) sur serveur Linux ou cloud managé.

**Repo GitHub :** `MGNetworking/swarm-iam-platform`
**Branches :** `main` (production) → `develop` (intégration) → `feat/*` / `fix/*` / `chore/*`

---

## Stack technique

| Service    | Version | Rôle                               |
| ---------- | ------- | ---------------------------------- |
| k3s        | stable  | Orchestrateur Kubernetes léger     |
| Traefik    | v3.1    | Ingress Controller / reverse proxy |
| Keycloak   | 26.0    | SSO / IAM                          |
| PostgreSQL | 17-alpine | Base de données                  |
| Redis      | 7-alpine  | Cache session (512mb max)        |

---

## Architecture réseau (Kubernetes)

- Namespace `iam-system` : tous les services IAM
- Communication interne via Services ClusterIP (DNS Kubernetes natif)
- Traefik comme IngressController pour exposer Keycloak vers l'extérieur
- TLS : à configurer via cert-manager (hors scope courant)

---

## Structure du projet

```
k8s/
  base/                        # Manifests Kubernetes communs (tous environnements)
    namespace.yaml
    traefik/
    postgresql/
    redis/
    keycloak/
    kustomization.yaml

  overlays/
    linux-server/              # VPS bare metal / Hetzner / OVH
      patches/
    cloud/
      azure/                   # AKS — Azure Kubernetes Service
        patches/
      aws/                     # EKS — Elastic Kubernetes Service
        patches/

environments/
  linux-server/
    .env                       # Variables runtime (hostname, DB, namespace)
    config.env                 # Variables opérationnelles (timeouts, overlay path)
  cloud/
    azure/
      .env
      config.env
    aws/
      .env
      config.env

scripts/                       # Scripts d'orchestration (kubectl)
  deploy-infra.sh              # Déploiement : kubectl apply -k (option --env requis)
  restart-infra.sh             # kubectl rollout restart sur tous les déploiements
  reset-infra.sh               # Réinitialisation destructive (namespace delete)
  ensure-infra.sh              # Vérifie k3s + kubectl + namespace iam-system
  ensure-backup-dirs.sh        # Crée les répertoires de backup sur l'hôte
  wait-for-it.sh               # Attente service TCP (script tiers, non modifié)

postgres_home/scripts/         # Scripts PostgreSQL (via kubectl exec)
  backup-daily-cluster.sh      # Backup quotidien cluster (rétention 30j)
  backup-manual.sh             # Backup manuel interactif (base ou schéma)
  restore-daily-cluster.sh     # Restauration depuis backup cluster
  restore-manual-db.sh         # Restauration base complète
  restore-manual-schema.sh     # Restauration schéma spécifique

secrets/
  secrets.manifest             # Liste des secrets K8s attendus (non commités)
  check-secrets.sh             # Vérifie la présence des secrets K8s

docs/
  plans/                       # Plans d'implémentation (plan-k3s-migration.md)
  adr/                         # Architecture Decision Records
```

---

## Secrets Kubernetes

Créés manuellement sur le cluster, **jamais commités** :

```bash
kubectl create secret generic pg-password \
  --from-literal=password=<value> -n iam-system

kubectl create secret generic redis-password \
  --from-literal=password=<value> -n iam-system
```

---

## Logs

Chemin configurable via `LOG_DIR` dans `environments/<env>/config.env`.
Valeur par défaut : `/var/log/swarm-iam`.

---

## Conventions de code

### Scripts Bash

- Toujours commencer par `set -euo pipefail`
- Résolution du `PROJECT_ROOT` via `SCRIPT_DIR` (portable, indépendant du cwd)
- Logging avec timestamp via fonction `log()` → fichier + stdout
- Variables d'environnement validées avec `: "${VAR:?message}"` en début de script
- Scripts **idempotents** — re-exécutables sans effets de bord
- Sélection de l'environnement via `--env <linux-server|cloud/azure|cloud/aws>`

### Manifests Kubernetes (Kustomize)

- `base/` : ressources communes à tous les environnements, sans valeurs hardcodées
- `overlays/<env>/` : patches uniquement pour ce qui diffère par environnement
- Namespace fixe : `iam-system`
- Labels obligatoires : `app.kubernetes.io/name`, `app.kubernetes.io/component`

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
- Cluster cible : k3s sur VPS Linux, ou AKS/EKS pour cloud
- SSH GitHub configuré depuis WSL2 (clé `~/.ssh/id_ed25519`)

---

## Points d'attention

- `reset-infra.sh` est **destructif** : supprime le namespace `iam-system` et toutes ses ressources
- Les secrets K8s sont créés manuellement sur le cluster (jamais dans le repo)
- Installation de k3s : hors scope des scripts (voir README pour la procédure)
- Les overlays `cloud/` nécessitent un cluster AKS ou EKS existant et `kubectl` configuré
