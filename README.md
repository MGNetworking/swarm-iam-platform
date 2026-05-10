# swarm-iam-platform

Plateforme IAM complète (Keycloak + PostgreSQL + Redis + Traefik) orchestrée avec **k3s** (Kubernetes léger).  
Architecture multi-environnements via **Kustomize** : dev local WSL2, VPS Linux, Azure (AKS), AWS (EKS).

---

## Stack

| Service    | Version   | Rôle                       |
| ---------- | --------- | -------------------------- |
| k3s        | stable    | Orchestrateur Kubernetes   |
| Traefik    | v3.1      | Ingress Controller         |
| Keycloak   | 26.0      | SSO / IAM                  |
| PostgreSQL | 17-alpine | Base de données            |
| Redis      | 7-alpine  | Cache session (512 MB max) |

---

## Environnements disponibles

| `--env`        | Cible                        | Cluster         |
| -------------- | ---------------------------- | --------------- |
| `local-dev`    | WSL2 (tests locaux)          | k3s single-node |
| `linux-server` | VPS bare metal (Hetzner/OVH) | k3s single-node |
| `cloud/azure`  | Azure Kubernetes Service     | AKS             |
| `cloud/aws`    | Elastic Kubernetes Service   | EKS             |

---

## Structure du dépôt

```
k8s/
  base/             Manifests Kubernetes communs (Traefik, PostgreSQL, Redis, Keycloak)
  overlays/
    local-dev/      Patches WSL2 dev local (StorageClass: local-path, hostname: keycloak.local)
    linux-server/   Patches VPS bare metal (StorageClass: local-path)
    cloud/azure/    Patches AKS (StorageClass: managed-csi)
    cloud/aws/      Patches EKS (StorageClass: gp2)

environments/
  local-dev/        .env + config.env pour WSL2 (dev local)
  linux-server/     .env + config.env pour VPS
  cloud/azure/      .env + config.env pour AKS
  cloud/aws/        .env + config.env pour EKS

scripts/            Orchestration (deploy, restart, reset, ensure)
postgres_home/      Scripts backup/restore PostgreSQL
secrets/            Manifest des secrets K8s + script de vérification

docs/
  environments/     Guides d'installation par environnement
  reference/        Documentation technique et décisions d'architecture
  k8s-course/       Cours Kubernetes (10 modules)
```

---

## Documentation

### Guides d'installation par environnement

| Environnement | Guide |
| --- | --- |
| WSL2 (dev local) | [docs/environments/local-dev.md](docs/environments/local-dev.md) |
| VPS Linux (k3s bare metal) | [docs/environments/linux-server.md](docs/environments/linux-server.md) |
| Azure AKS | [docs/environments/azure.md](docs/environments/azure.md) |
| AWS EKS | [docs/environments/aws.md](docs/environments/aws.md) |

### Référence technique

| Document | Contenu |
| --- | --- |
| [Scripts — Guide complet](docs/reference/scripts.md) | Scénarios d'utilisation, fonctionnement interne, commandes kubectl |
| [Kubernetes — Manifests et dépendances](docs/reference/kubernetes-manifests.md) | Rôle de chaque YAML, schémas de dépendances, overlays |
| [Architecture k3s](docs/reference/architecture-k3s.md) | Fonctionnement des composants et communication interne |
| [PostgreSQL sur Kubernetes](docs/reference/postgresql-k8s.md) | StatefulSet, PVC, backups, restore |
| [CI — GitHub Actions](docs/reference/ci-github-actions.md) | Pipeline d'intégration continue |

### Décisions et historique

| Document | Contenu |
| --- | --- |
| [Décisions d'architecture](docs/reference/decisions.md) | Migration k3s et choix de Kustomize — contexte et alternatives rejetées |
