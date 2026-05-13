# Scripts — Guide complet

Deux familles de scripts, un seul projet :

```
scripts/                  ← Orchestration Kubernetes (déploiement, restart, reset)
postgres_home/scripts/    ← Opérations PostgreSQL (backup, restore via kubectl exec)
```

Ces deux familles ne s'appellent pas entre elles. Chacune a son périmètre :

- `scripts/` → parle à **Kubernetes** (kubectl)
- `postgres_home/scripts/` → parle à **PostgreSQL** (via kubectl exec dans le pod)

---

## Sommaire

- [Tableau récapitulatif](#tableau-récapitulatif)
- [Environnements disponibles](#environnements-disponibles)
- [Scénarios d'utilisation](#scénarios-dutilisation)
  - [Premier déploiement sur un VPS](#premier-déploiement-sur-un-vps)
  - [Mise à jour / redéploiement](#mise-à-jour-redéploiement)
  - [Redémarrer tous les services](#redémarrer-tous-les-services)
  - [Réinitialisation](#réinitialisation)
  - [Backup quotidien (à planifier via cron)](#backup-quotidien--cronjob-kubernetes)
  - [Backup manuel](#backup-manuel)
  - [Restauration depuis un backup daily](#restauration-depuis-un-backup-daily)
  - [Restauration d'une base unique](#restauration-dune-base-unique)
  - [Restauration du schéma uniquement](#restauration-du-schéma-uniquement)
  - [Déploiement cloud](#déploiement-cloud)
- [Commandes kubectl utiles](#commandes-kubectl-utiles)
- [Comment fonctionne `kubectl apply -k`](#comment-fonctionne-kubectl-apply--k)
- [Comment `deploy-infra.sh` fonctionne en détail](#comment-deploy-infrash-fonctionne-en-détail)
- [Schéma d'appel entre les scripts](#schéma-dappel-entre-les-scripts)
- [Mécanique commune à tous les scripts](#mécanique-commune-à-tous-les-scripts)
  - [Garde-fou en tête de script](#garde-fou-en-tête-de-script)
  - [Résolution du répertoire racine](#résolution-du-répertoire-racine)
  - [Chargement des fichiers `.env`](#chargement-des-fichiers-env)
  - [Validation des variables requises](#validation-des-variables-requises)
  - [Logging avec timestamp](#logging-avec-timestamp)
  - [Les deux fichiers de configuration](#les-deux-fichiers-de-configuration)

---

## Tableau récapitulatif

| Script                     | Ce qu'il fait                          | Quand l'utiliser                 | Dangereux ?                  |
| -------------------------- | -------------------------------------- | -------------------------------- | ---------------------------- |
| `ensure-infra.sh`               | Vérifie k3s + cluster + namespace           | Avant tout déploiement           | Non                          |
| `deploy-infra.sh`               | Déploie ou met à jour toute la stack        | Premier déploiement, mise à jour | Non (idempotent)             |
| `setup-eso.sh`                  | Installe External Secrets Operator          | Une seule fois avant deploy      | Non (idempotent)             |
| `secrets/setup-infisical.sh`    | Crée le secret credentials Infisical dans K8s | Après setup-eso, avant deploy  | Non (idempotent)             |
| `restart-infra.sh`              | Redémarre les pods un par un                | Après un changement de secret    | Non (progressif)             |
| `reset-infra.sh`                | Supprime tout le namespace                  | Repartir de zéro                 | **OUI — irréversible**       |
| `ensure-backup-dirs.sh`         | Crée les dossiers de backup sur l'hôte      | Avant le premier déploiement     | Non                          |
| `backup-manual.sh`              | Dump interactif d'une base                  | Avant une migration risquée      | Non                          |
| `restore-daily-cluster.sh`      | Restaure depuis backup daily                | Restauration complète            | **Oui** — écrase les données |
| `restore-manual-db.sh`          | Restaure une base complète                  | Restauration ciblée              | **Oui** — écrase la base     |
| `restore-manual-schema.sh`      | Restaure la structure uniquement            | Corriger une migration           | **Oui** — perte des données  |

---

## Environnements disponibles

| Valeur `--env` | Cible                          | Cluster         |
| -------------- | ------------------------------ | --------------- |
| `local-dev`    | WSL2 (tests locaux)            | k3s single-node |
| `linux-server` | VPS bare metal (Hetzner, OVH…) | k3s single-node |
| `cloud/azure`  | Azure Kubernetes Service       | AKS             |
| `cloud/aws`    | Elastic Kubernetes Service     | EKS             |

> Tous les scripts du projet acceptent `--env`. Remplace `linux-server` par ta cible.

---

## Scénarios d'utilisation

### Premier déploiement sur un VPS

```bash
# 0. Prérequis : k3s installé, kubectl configuré, secrets K8s créés
#    Voir docs/environments/linux-server.md pour les commandes kubectl create secret

# 1. Adapter la configuration
vi environments/linux-server/.env
vi k8s/overlays/linux-server/patches/keycloak-hostname.yaml

# 2. Vérifier les prérequis
./scripts/ensure-infra.sh --env linux-server

# 3. Déployer
./scripts/deploy-infra.sh --env linux-server

# 4. Suivre le démarrage en temps réel
kubectl get pods -n iam-system -w
```

### Mise à jour / redéploiement

```bash
# Après modification d'un manifest ou d'un patch overlay
./scripts/deploy-infra.sh --env linux-server
# kubectl apply -k est idempotent : seuls les changements sont appliqués
```

### Redémarrer tous les services

```bash
# Redémarre dans l'ordre : Traefik → PostgreSQL → Redis → Keycloak
./scripts/restart-infra.sh --env linux-server
```

### Réinitialisation

```bash
# ⚠ CONSERVE les données PostgreSQL et Redis (recommandé)
./scripts/reset-infra.sh --env linux-server --keep-data

# ⚠⚠ SUPPRIME TOUT, données incluses (irrécupérable)
./scripts/reset-infra.sh --env linux-server
```

Après un reset, relancer un déploiement complet :

```bash
./scripts/deploy-infra.sh --env linux-server
```

### Backup quotidien — CronJob Kubernetes

Le backup quotidien est géré par un **CronJob Kubernetes** déployé dans le cluster.
Il n'y a rien à planifier manuellement dans `crontab`.

```bash
# Vérifier que le CronJob est actif
kubectl get cronjob -n iam-system

# Voir l'historique des jobs exécutés
kubectl get jobs -n iam-system

# Logs du dernier backup
kubectl logs -n iam-system -l app.kubernetes.io/name=postgresql-backup --tail=30
```

| Environnement  | Stockage des backups                     | Outil                    |
| -------------- | ---------------------------------------- | ------------------------ |
| `linux-server` | `/var/backups/postgresql/` (disque VPS)  | hostPath k8s             |
| `cloud/azure`  | Azure Blob Storage _(Step 2 — planifié)_ | `az storage blob upload` |
| `cloud/aws`    | AWS S3 Bucket _(Step 2 — planifié)_      | `aws s3 sync`            |

Rétention : 30 jours (variable `KEEP_DAYS` dans le CronJob).  
Voir [docs/environments/linux-server.md](../environments/linux-server.md) pour la procédure complète.

### Backup manuel

```bash
./postgres_home/scripts/backup-manual.sh
```

Le script te demande quelle base sauvegarder et quel mode :

- **Base complète** → `postgres_home/backups/manual/BD/`
- **Schéma uniquement** → `postgres_home/backups/manual/schema/`

### Restauration depuis un backup daily

```bash
# Lister les backups disponibles (linux-server)
ls /var/backups/postgresql/

# Restaurer
./postgres_home/scripts/restore-daily-cluster.sh --env linux-server CLUSTER-2025-12-28.sql.gz
```

Le script arrête Keycloak, restaure toutes les bases depuis `/var/backups/postgresql/`, relance Keycloak.

### Restauration d'une base unique

```bash
ls postgres_home/backups/manual/BD/
./postgres_home/scripts/restore-manual-db.sh --env linux-server kc_db-2025-12-28_143000.sql.gz
```

### Restauration du schéma uniquement

```bash
ls postgres_home/backups/manual/schema/
./postgres_home/scripts/restore-manual-schema.sh --env linux-server kc_db-schema-2025-12-28_143000.sql.gz
```

> Le schéma est restauré dans une base vide — les données existantes sont perdues.
> Cas d'usage : corriger une migration de schéma qui a mal tourné.

### Déploiement cloud

```bash
# Azure (AKS) — après avoir configuré kubectl pour le cluster AKS
./scripts/deploy-infra.sh --env cloud/azure

# AWS (EKS) — après avoir configuré kubectl pour le cluster EKS
./scripts/deploy-infra.sh --env cloud/aws
```

---

## Commandes kubectl utiles

```bash
# État de tous les pods de la plateforme
kubectl get pods -n iam-system

# Logs en temps réel
kubectl logs -n iam-system deployment/keycloak -f
kubectl logs -n iam-system statefulset/postgresql -f
kubectl logs -n iam-system deployment/traefik -f
kubectl logs -n iam-system deployment/redis -f

# Ouvrir un shell dans un pod
kubectl exec -it -n iam-system postgresql-0 -- sh
kubectl exec -it -n iam-system deployment/keycloak -- sh

# Vérifier les volumes (disques persistants)
kubectl get pvc -n iam-system

# Vérifier les secrets K8s
./secrets/check-secrets.sh --env linux-server

# Voir le résultat Kustomize sans déployer
kubectl kustomize k8s/overlays/linux-server/
```

---

## Comment fonctionne `kubectl apply -k`

Quand `deploy-infra.sh` lance cette commande :

```bash
kubectl apply -k "$PROJECT_ROOT/k8s/overlays/linux-server"
```

Kustomize lit les fichiers dans cet ordre :

```
kubectl apply -k k8s/overlays/linux-server/
        │
        ▼
  kustomization.yaml  ← lu EN PREMIER (toujours)
  (overlays/linux-server/)
        │
        ├── resources: ../../base  ← charge tout k8s/base/
        │       │
        │       └── kustomization.yaml (base/)
        │               ├── namespace.yaml
        │               ├── traefik/       → ses fichiers yaml
        │               ├── postgresql/    → ses fichiers yaml
        │               ├── redis/         → ses fichiers yaml
        │               └── keycloak/      → ses fichiers yaml
        │
        └── patches:              ← modifications par-dessus la base
                ├── patches/postgresql-storage.yaml
                ├── patches/redis-storage.yaml
                ├── patches/keycloak-hostname.yaml
                └── patches/keycloak-ingress.yaml
```

Kustomize assemble tout en mémoire et envoie d'un seul coup au cluster.
Le patch ne remplace pas la base — il vient **par-dessus**, uniquement sur les champs spécifiés.

---

## Comment `deploy-infra.sh` fonctionne en détail

```bash
./scripts/deploy-infra.sh --env linux-server
```

**Étape 0 — Charger la configuration**

Charge `environments/linux-server/.env` + `config.env`. Si une variable obligatoire manque, le script s'arrête.

**Étape 1 — Vérifier les prérequis**

Appelle `ensure-infra.sh` : kubectl disponible → cluster répond → namespace `iam-system` existe.

**Étape 2 — Créer les répertoires de backup**

`ensure-backup-dirs.sh` crée `postgres_home/backups/daily/cluster/`, `manual/BD/`, `manual/schema/`.

**Étape 3 — Déployer les manifests Kustomize**

```bash
kubectl apply -k k8s/overlays/linux-server/
```

**Étape 4 — Attendre la stabilisation des pods**

```
Traefik    → 180s  (doit être up avant Keycloak)
PostgreSQL → 240s  (StatefulSet, plus lent à démarrer)
Redis      → 180s
Keycloak   → 300s  (JVM + connexion à PostgreSQL)
```

**Étape 5 — Vérifier que Keycloak répond** (curl, non bloquant)

**Étape 6 — Résumé** : `kubectl get pods -n iam-system`

---

## Schéma d'appel entre les scripts

```
deploy-infra.sh --env linux-server
        │
        ├──► ensure-infra.sh          (vérifications prérequis)
        │         ├── kubectl check
        │         ├── cluster ready ?
        │         └── namespace iam-system créé si absent
        │
        ├──► ensure-backup-dirs.sh    (crée dossiers backup)
        │
        ├──► kubectl apply -k         (déploie base + overlay)
        │         └── lit kustomization.yaml → assemble tout
        │
        └──► kubectl rollout status   (attend chaque pod)
                  ├── traefik
                  ├── postgresql
                  ├── redis
                  └── keycloak


restart-infra.sh --env linux-server
        └──► kubectl rollout restart  (remplace pod par pod, sans coupure)

reset-infra.sh --env linux-server
        └──► kubectl delete namespace (supprime tout — irréversible)
```

---

## Mécanique commune à tous les scripts

### Garde-fou en tête de script

```bash
set -euo pipefail
```

- `-e` : arrête le script dès qu'une commande échoue
- `-u` : arrête si une variable non définie est utilisée
- `-o pipefail` : arrête si une commande dans un pipe échoue

### Résolution du répertoire racine

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
```

Peu importe d'où tu lances le script, il calcule toujours son chemin absolu.

### Chargement des fichiers `.env`

```bash
set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  source "$CONF_FILE"
done
set +a
```

`set -a` exporte automatiquement toutes les variables définies (disponibles dans les sous-processus).

### Validation des variables requises

```bash
: "${KEYCLOAK_HOSTNAME:?KEYCLOAK_HOSTNAME manquant dans $ENV_DIR/.env}"
```

Si la variable est vide ou absente → le script s'arrête et affiche le message d'erreur.

### Logging avec timestamp

```bash
log() { echo "$(ts) - $*" | tee -a "$LOG_FILE"; }
die() { log "ERREUR: $*"; exit 1; }
```

`log` écrit dans le terminal ET dans le fichier de log. `die` loggue et arrête le script.

### Les deux fichiers de configuration

**`.env`** — variables runtime (ce qui est déployé) :

```bash
NAMESPACE=iam-system
KEYCLOAK_HOSTNAME=keycloak.example.com
DB_NAME=kc_db
```

**`config.env`** — comportement des scripts :

```bash
MAX_WAIT=300
K8S_OVERLAY=k8s/overlays/linux-server
LOG_DIR=/var/log/swarm-iam
```
