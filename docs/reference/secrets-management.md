# Gestion des secrets — Infisical + ESO

## Pourquoi ce système

Le projet gère plusieurs environnements (linux-server, cloud/azure, cloud/aws, local-dev).
Chaque environnement a besoin des mêmes secrets applicatifs (mots de passe PostgreSQL, Redis,
Keycloak) mais les stocker dans des fichiers `.env` sur chaque serveur pose plusieurs problèmes :

- **Fichiers en clair sur disque** — tout accès au serveur expose les mots de passe
- **Pas de traçabilité** — impossible de savoir qui a lu ou modifié un secret
- **Pas de rotation centralisée** — changer un mot de passe = modifier N fichiers sur N serveurs
- **Pas de contrôle d'accès** — n'importe qui avec accès au repo ou au serveur voit tout

La solution retenue : **Infisical SaaS + External Secrets Operator (ESO)**.

---

## Les deux composants

### External Secrets Operator (ESO)

ESO est un **opérateur Kubernetes** — un programme qui tourne dans le cluster et surveille
des ressources K8s personnalisées (CRDs). Il joue le rôle d'intermédiaire entre le cluster
et le gestionnaire de secrets externe.

ESO répond à deux questions :
- **Où sont les secrets ?** → défini par le `ClusterSecretStore` (qui pointe vers Infisical)
- **Quels secrets récupérer ?** → défini par les `ExternalSecret` (un par secret K8s à créer)

ESO est installé dans son propre namespace `external-secrets`, séparé du namespace applicatif
`iam-system`. Il a accès cluster-wide pour créer des Secrets dans n'importe quel namespace.

### Infisical

Infisical est un **gestionnaire de secrets SaaS** (Software as a Service). C'est le coffre-fort
central qui stocke tous les mots de passe et valeurs sensibles. Il est accessible via API depuis
n'importe quel environnement — VPS, AKS, EKS, poste local.

Infisical organise les secrets en **projets** et **environnements** :

```
Projet : swarm-iam-platform
  ├── Environnement : prod          → linux-server
  ├── Environnement : prod-azure    → cloud/azure
  ├── Environnement : prod-aws      → cloud/aws
  └── Environnement : dev           → local-dev
```

---

## Architecture complète

```
┌─────────────────────────────────────────────────────┐
│  Infisical SaaS (app.infisical.com)                 │
│                                                     │
│  Projet swarm-iam-platform / env: prod              │
│    PG_PASSWORD        = ••••••••                    │
│    REDIS_PASSWORD     = ••••••••                    │
│    KEYCLOAK_ADMIN_PASSWORD = ••••••••               │
│    RCLONE_CONF        = [contenu rclone.conf]       │
│    RCLONE_SSH_KEY     = [clé privée SSH]            │
│    RCLONE_KNOWN_HOSTS = [known_hosts]               │
└──────────────────┬──────────────────────────────────┘
                   │ API HTTPS (Universal Auth)
                   │ credentials : infisical-credentials (K8s Secret)
                   │
┌──────────────────▼──────────────────────────────────┐
│  Namespace : external-secrets (cluster K8s)         │
│                                                     │
│  ESO (External Secrets Operator)                    │
│    ├── ClusterSecretStore "infisical-store"         │
│    │     └── pointe vers Infisical via credentials  │
│    │                                                │
│    └── Surveille les ExternalSecret dans le cluster │
└──────────────────┬──────────────────────────────────┘
                   │ crée / met à jour automatiquement
                   │
┌──────────────────▼──────────────────────────────────┐
│  Namespace : iam-system                             │
│                                                     │
│  Kubernetes Secrets (natifs, opaques)               │
│    ├── pg-password          (key: password)         │
│    ├── redis-password       (key: password)         │
│    ├── keycloak-admin       (key: password)         │
│    ├── rclone-config        (key: rclone.conf)      │
│    └── rclone-nas-key       (key: key, known_hosts) │
│                                                     │
│  Pods applicatifs                                   │
│    ├── PostgreSQL  ──────── lit pg-password         │
│    ├── Redis       ──────── lit redis-password      │
│    ├── Keycloak    ──────── lit keycloak-admin      │
│    └── CronJob rclone ───── lit rclone-*            │
└─────────────────────────────────────────────────────┘
```

---

## Ressources Kubernetes créées

### ClusterSecretStore

Ressource cluster-wide (pas de namespace). Configure ESO pour s'authentifier auprès d'Infisical.
Un `ClusterSecretStore` par overlay — chaque environnement pointe vers son env Infisical.

| Overlay | Fichier | envSlug Infisical |
|---|---|---|
| linux-server | `k8s/overlays/linux-server/cluster-secret-store.yaml` | `prod` |
| cloud/azure | `k8s/overlays/cloud/azure/cluster-secret-store.yaml` | `prod-azure` |
| cloud/aws | `k8s/overlays/cloud/aws/cluster-secret-store.yaml` | `prod-aws` |
| local-dev | `k8s/overlays/local-dev/cluster-secret-store.yaml` | `dev` |

### ExternalSecret

Ressource namespace-scoped. Définit quel secret Infisical → quel Secret K8s.

**Communs à tous les environnements** (`k8s/base/external-secrets/`) :

| Fichier | Secret K8s créé | Clé Infisical |
|---|---|---|
| `pg-password.yaml` | `pg-password` (key: `password`) | `PG_PASSWORD` |
| `redis-password.yaml` | `redis-password` (key: `password`) | `REDIS_PASSWORD` |
| `keycloak-admin.yaml` | `keycloak-admin` (key: `password`) | `KEYCLOAK_ADMIN_PASSWORD` |

**Spécifiques linux-server** (`k8s/overlays/linux-server/external-secrets/`) :

| Fichier | Secret K8s créé | Clés Infisical |
|---|---|---|
| `rclone-config.yaml` | `rclone-config` (key: `rclone.conf`) | `RCLONE_CONF` |
| `rclone-nas-key.yaml` | `rclone-nas-key` (key: `key`, `known_hosts`) | `RCLONE_SSH_KEY`, `RCLONE_KNOWN_HOSTS` |

---

## Flux de déploiement complet

```
1. setup-eso.sh
   └── installe ESO dans le namespace "external-secrets" (une seule fois)

2. Créer les secrets dans Infisical (UI web — une seule fois)
   └── PG_PASSWORD, REDIS_PASSWORD, KEYCLOAK_ADMIN_PASSWORD
   └── RCLONE_CONF, RCLONE_SSH_KEY, RCLONE_KNOWN_HOSTS (linux-server uniquement)

3. Renseigner INFISICAL_CLIENT_ID + INFISICAL_CLIENT_SECRET dans environments/<env>/.env

4. secrets/setup-infisical.sh --env <environnement>
   └── crée le secret K8s "infisical-credentials" dans external-secrets

5. scripts/deploy-infra.sh --env <environnement>
   └── kubectl apply -k k8s/overlays/<env>
         ├── déploie ClusterSecretStore → ESO connaît Infisical
         ├── déploie ExternalSecrets → ESO sait quoi récupérer
         └── ESO contacte Infisical → crée automatiquement les K8s Secrets
               → PostgreSQL, Redis, Keycloak démarrent avec leurs secrets
```

---

## Contenu des secrets Infisical à créer

### Secrets communs (tous environnements)

| Clé Infisical | Description | Exemple |
|---|---|---|
| `PG_PASSWORD` | Mot de passe PostgreSQL | `motdepasse-fort-32-chars` |
| `REDIS_PASSWORD` | Mot de passe Redis | `motdepasse-fort-32-chars` |
| `KEYCLOAK_ADMIN_PASSWORD` | Mot de passe admin Keycloak | `motdepasse-fort-32-chars` |

### Secrets spécifiques linux-server

| Clé Infisical | Description |
|---|---|
| `RCLONE_CONF` | Contenu complet du fichier `rclone.conf` (voir ci-dessous) |
| `RCLONE_SSH_KEY` | Contenu de la clé privée SSH `~/.ssh/id_ed25519_nas_backup` |
| `RCLONE_KNOWN_HOSTS` | Sortie de `ssh-keyscan -H -p <SFTP_PORT> <SFTP_HOST>` |

**Format attendu pour `RCLONE_CONF` :**

```ini
[nas-backup]
type = sftp
host = <SFTP_HOST>
port = <SFTP_PORT>
user = <SFTP_USER>
key_file = /secrets/key
known_hosts_file = /secrets/known_hosts
```

---

## Comportement en cas de panne Infisical

Si Infisical est temporairement inaccessible :

- Les **Kubernetes Secrets existants** restent en place — les pods continuent de tourner
- ESO ne peut plus **créer ou mettre à jour** de secrets pendant la panne
- Au retour d'Infisical, ESO resynchronise automatiquement (intervalle : 1h)
- **Aucune intervention manuelle** requise pour la récupération

---

## Changer de gestionnaire de secrets

ESO est agnostique du backend. Si tu veux remplacer Infisical par HashiCorp Vault ou
un service cloud natif (AWS Secrets Manager, Azure Key Vault), seul le `ClusterSecretStore`
change. Les `ExternalSecret` restent identiques.

| Backend | Provider ESO |
|---|---|
| Infisical | `infisical` |
| HashiCorp Vault | `vault` |
| AWS Secrets Manager | `aws` |
| Azure Key Vault | `azurekv` |
| GCP Secret Manager | `gcpsm` |
