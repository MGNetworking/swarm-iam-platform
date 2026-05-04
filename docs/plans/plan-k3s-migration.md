# Plan : Migration Docker Swarm → k3s + Restructuration multi-environnements

Créé le : 2026-05-04 | Branche : feat/refactoring-projet | Niveau : 2 (Standard)

## Résumé

Migration complète de l'infrastructure IAM (Keycloak + PostgreSQL + Redis + Traefik) depuis
Docker Swarm vers k3s (Kubernetes léger). Suppression de l'environnement homeLab Synology.
La nouvelle architecture cible deux environnements : `linux-server` (VPS bare metal avec k3s)
et `cloud` (Azure ou AWS). Les manifests Kubernetes sont organisés avec Kustomize : une base
commune et des overlays par environnement pour les différences de stockage, ressources et DNS.

---

## Décisions

| # | Décision | Justification |
|---|----------|---------------|
| 1 | Migration Docker Swarm → k3s | Portabilité VPS + cloud managé (AKS/EKS), écosystème standardisé, pérenne sur 3+ ans |
| 2 | Suppression de `environments/homeLab/` | Synology NAS hors scope, remplacé par linux-server générique |
| 3 | Environnements cibles : `linux-server` + `cloud` | VPS k3s pour usage courant, cloud Azure/AWS pour gros projets futurs |
| 4 | Format manifests : Kustomize | Intégré dans kubectl, base commune + overlays env, zéro dépendance externe |
| 5 | Branche de travail : `feat/refactoring-projet` | Tout le refactoring isolé, PR vers develop quand stable |

---

## Architecture cible

```
k8s/
  base/                        # Manifests Kubernetes communs (tous environnements)
    namespace.yaml
    traefik/
      deployment.yaml
      service.yaml
      ingressclass.yaml
      kustomization.yaml
    postgresql/
      statefulset.yaml
      service.yaml
      pvc.yaml
      configmap-init.yaml
      kustomization.yaml
    redis/
      deployment.yaml
      service.yaml
      configmap.yaml
      kustomization.yaml
    keycloak/
      deployment.yaml
      service.yaml
      ingress.yaml
      kustomization.yaml
    kustomization.yaml

  overlays/
    linux-server/              # VPS bare metal / Hetzner / OVH
      kustomization.yaml       # patches : StorageClass local, resources VPS, hostname
      patches/
        postgresql-storage.yaml
        redis-resources.yaml
        keycloak-ingress.yaml
    cloud/
      azure/                   # AKS — Azure Kubernetes Service
        kustomization.yaml     # patches : StorageClass azure-disk, resources cloud
        patches/
          postgresql-storage.yaml
          keycloak-ingress.yaml
      aws/                     # EKS — Elastic Kubernetes Service
        kustomization.yaml     # patches : StorageClass gp2/gp3, resources cloud
        patches/
          postgresql-storage.yaml
          keycloak-ingress.yaml

environments/
  linux-server/
    .env                       # KEYCLOAK_HOSTNAME, DEPLOY_NODE, LOG_DIR
    config.env                 # MAX_WAIT, WAIT_INTERVAL
  cloud/
    azure/
      .env
      config.env
    aws/
      .env
      config.env

scripts/                       # Réécrits pour k3s
  deploy-infra.sh              # kubectl apply -k
  ensure-infra.sh              # Vérifie k3s + kubectl + namespaces
  restart-infra.sh             # Redémarre les déploiements k3s
  reset-infra.sh               # Supprime les namespaces (destructif)
  ensure-backup-dirs.sh        # Crée répertoires backup sur l'hôte
  wait-for-it.sh               # Inchangé (script tiers)

postgres_home/scripts/         # Adaptés pour kubectl exec
  backup-daily-cluster.sh
  backup-manual.sh
  restore-daily-cluster.sh
  restore-manual-db.sh
  restore-manual-schema.sh

docs/
  plans/
  adr/
```

---

## Tâches

### Couche 1 — Fondation structurelle
*Pré-requis : aucun. Pose les bases de la nouvelle structure.*

- [ ] Supprimer `environments/homeLab/` (stacks Swarm + configs Synology)
- [ ] Créer l'arborescence `k8s/base/` avec les sous-dossiers par service
- [ ] Créer `k8s/overlays/linux-server/`, `k8s/overlays/cloud/azure/`, `k8s/overlays/cloud/aws/`
- [ ] Créer `environments/linux-server/` avec `.env` et `config.env` (valeurs Linux génériques)
- [ ] Créer `environments/cloud/azure/` et `environments/cloud/aws/` avec `.env` et `config.env`
- [ ] Mettre à jour `CLAUDE.md` (nouvelle stack technique, nouvelle structure)
- [ ] Créer ADR-0001 : Migration Swarm → k3s

### Couche 2 — Manifests k3s base (Traefik + réseau)
*Dépend de : Couche 1*

- [ ] `k8s/base/namespace.yaml` — namespace `iam-system`
- [ ] `k8s/base/traefik/deployment.yaml` — Traefik v3.1, IngressController
- [ ] `k8s/base/traefik/service.yaml` — Service LoadBalancer port 80/443
- [ ] `k8s/base/traefik/ingressclass.yaml` — IngressClass `traefik`
- [ ] `k8s/base/traefik/kustomization.yaml`
- [ ] Critères d'acceptation : `kubectl apply -k k8s/base/traefik/` sans erreur

### Couche 3 — Manifests k3s base (PostgreSQL)
*Dépend de : Couche 1*

- [ ] `k8s/base/postgresql/statefulset.yaml` — PostgreSQL 17-alpine, secret pg_password
- [ ] `k8s/base/postgresql/service.yaml` — ClusterIP + alias DNS `dns-postgres`
- [ ] `k8s/base/postgresql/pvc.yaml` — PersistentVolumeClaim (StorageClass : paramétrable)
- [ ] `k8s/base/postgresql/configmap-init.yaml` — scripts d'initialisation DB
- [ ] `k8s/base/postgresql/kustomization.yaml`
- [ ] Critères d'acceptation : Pod PostgreSQL `Running`, connexion depuis un pod test

### Couche 4 — Manifests k3s base (Redis + Keycloak)
*Dépend de : Couche 1*

- [ ] `k8s/base/redis/deployment.yaml` — Redis 7-alpine, secret redis_password, 512mb max
- [ ] `k8s/base/redis/service.yaml` — ClusterIP port 6379
- [ ] `k8s/base/redis/configmap.yaml` — redis.conf (maxmemory, policy)
- [ ] `k8s/base/redis/kustomization.yaml`
- [ ] `k8s/base/keycloak/deployment.yaml` — Keycloak 26.0, variables env, attente PostgreSQL
- [ ] `k8s/base/keycloak/service.yaml` — ClusterIP port 8080
- [ ] `k8s/base/keycloak/ingress.yaml` — Ingress Traefik (hostname paramétrable)
- [ ] `k8s/base/keycloak/kustomization.yaml`
- [ ] `k8s/base/kustomization.yaml` — kustomization racine
- [ ] Critères d'acceptation : Keycloak accessible via navigateur sur le hostname configuré

### Couche 5 — Overlays par environnement
*Dépend de : Couches 2, 3, 4*

- [ ] `k8s/overlays/linux-server/kustomization.yaml` — patches StorageClass `local-path` (k3s défaut), hostname VPS
- [ ] `k8s/overlays/linux-server/patches/` — ajustements ressources VPS (limits/requests)
- [ ] `k8s/overlays/cloud/azure/kustomization.yaml` — StorageClass `managed-csi`, hostname Azure
- [ ] `k8s/overlays/cloud/aws/kustomization.yaml` — StorageClass `gp2`, hostname AWS
- [ ] Critères d'acceptation : `kubectl apply -k k8s/overlays/linux-server/` déploie sans erreur

### Couche 6 — Scripts d'orchestration
*Dépend de : Couche 5*

- [ ] Réécrire `scripts/ensure-infra.sh` — vérifie k3s installé, kubectl disponible, namespace `iam-system` présent
- [ ] Réécrire `scripts/deploy-infra.sh` — accepte `--env <linux-server|cloud/azure|cloud/aws>`, appelle `kubectl apply -k`
- [ ] Adapter `scripts/restart-infra.sh` — `kubectl rollout restart` sur tous les déploiements
- [ ] Adapter `scripts/reset-infra.sh` — `kubectl delete namespace iam-system` (confirmation requise)
- [ ] Adapter `scripts/ensure-backup-dirs.sh` — chemins portables (plus de `/volume1/`)
- [ ] Critères d'acceptation : shellcheck passe sur tous les scripts

### Couche 7 — Backup/Restore PostgreSQL
*Dépend de : Couche 3*

- [ ] Adapter `postgres_home/scripts/backup-daily-cluster.sh` — `kubectl exec` dans le pod PostgreSQL
- [ ] Adapter `postgres_home/scripts/backup-manual.sh` — même mécanique
- [ ] Adapter `postgres_home/scripts/restore-daily-cluster.sh`
- [ ] Adapter `postgres_home/scripts/restore-manual-db.sh`
- [ ] Adapter `postgres_home/scripts/restore-manual-schema.sh`
- [ ] Créer `k8s/base/postgresql/cronjob-backup.yaml` — CronJob K8s pour backup quotidien
- [ ] Critères d'acceptation : backup crée un fichier `.dump`, restore fonctionne depuis ce fichier

### Couche 8 — CI/CD
*Dépend de : Couche 6*

- [ ] Mettre à jour `.github/workflows/ci.yml` — ajouter validation manifests K8s (kubeconform)
- [ ] Vérifier shellcheck sur les scripts réécrits
- [ ] Mettre à jour Release Please si nécessaire
- [ ] Critères d'acceptation : CI verte sur PR vers develop

### Couche 9 — Documentation
*Dépend de : Couches 6, 7*

- [ ] `README.md` — réécrire : présentation k3s, prérequis, guide déploiement linux-server step-by-step
- [ ] `docs/adr/ADR-0001-k3s-migration.md` — formaliser la décision Swarm → k3s
- [ ] `docs/adr/ADR-0002-kustomize.md` — formaliser le choix Kustomize vs Helm
- [ ] Mettre à jour `CLAUDE.md` (stack finale, nouvelle structure)

---

## Plan de test

| Couche | Comment vérifier |
|--------|-----------------|
| 2-4 | `kubectl apply -k k8s/base/` + `kubectl get pods -n iam-system` |
| 5 | `kubectl apply -k k8s/overlays/linux-server/` + vérifier les patches appliqués |
| 6 | Shellcheck CI + exécution manuelle sur une VM de test |
| 7 | Backup → vérifier fichier .dump, restore → vérifier données en base |
| 8 | CI verte sur la PR feat/refactoring-projet → develop |

---

## Vérification d'intégration

```bash
# Vérifier la structure Kustomize
kubectl kustomize k8s/overlays/linux-server/

# Déploiement complet
./scripts/deploy-infra.sh --env linux-server

# Vérifier tous les pods running
kubectl get pods -n iam-system

# Vérifier Keycloak accessible
curl -I http://<KEYCLOAK_HOSTNAME>/health
```

---

## Hors périmètre

- Installation de k3s sur le serveur cible (procédure externe, documentée dans README)
- Migration des données existantes depuis le Synology NAS
- Configuration TLS/cert-manager (à prévoir dans une itération future)
- Monitoring Prometheus/Grafana (backlog, itération future)
- Alerting (backlog, itération future)
