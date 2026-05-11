# Développement local — WSL2

Guide complet de la mise en service à la suppression, sans toucher à la configuration VPS.

---

## Sommaire

- [Prérequis](#prérequis)
- [1 — Installer k3s](#1-installer-k3s)
- [2 — Configurer le hostname local](#2-configurer-le-hostname-local)
  - [Trouver l'IP WSL2](#trouver-lip-wsl2)
  - [Ajouter dans WSL2](#ajouter-dans-wsl2)
  - [Ajouter dans Windows](#ajouter-dans-windows)
- [3 — Premier lancement](#3-premier-lancement)
  - [Créer les secrets Kubernetes](#créer-les-secrets-kubernetes)
  - [Déployer la stack](#déployer-la-stack)
  - [Surveiller le démarrage](#surveiller-le-démarrage)
- [Logs par service](#logs-par-service)
- [Arrêter / reprendre les services](#arrêter-reprendre-les-services)
  - [Option 1 — Arrêter k3s entièrement (recommandé)](#option-1-arrêter-k3s-entièrement-recommandé)
  - [Option 2 — Scaler les pods à 0 (arrêt sélectif)](#option-2-scaler-les-pods-à-0-arrêt-sélectif)
- [Réinitialisation](#réinitialisation)
  - [Reset en conservant les données (recommandé)](#reset-en-conservant-les-données-recommandé)
  - [Reset complet (supprime toutes les données)](#reset-complet-supprime-toutes-les-données)
- [Sauvegardes PostgreSQL](#sauvegardes-postgresql)

---


## Prérequis

- WSL2 avec Ubuntu (ou équivalent)
- Au moins **2 vCPU / 2 GB RAM** alloués à WSL2
- Ports 80 et 443 libres sur la machine Windows

---

## 1 — Installer k3s

```bash
# Désactiver le Traefik intégré (v2.x) — ce projet déploie Traefik v3.1
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -

# Vérifier que le nœud est Ready
sudo kubectl get nodes
```

---

## 2 — Configurer le hostname local

### Trouver l'IP WSL2

```bash
ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1
# Exemple : 172.22.112.91
```

### Ajouter dans WSL2

```bash
echo "172.22.112.91  keycloak.local" | sudo tee -a /etc/hosts
```

Vérifier :

```bash
grep keycloak /etc/hosts
# Attendu : 172.22.112.91  keycloak.local
```

### Ajouter dans Windows

Dans un terminal **PowerShell en mode administrateur** :

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "172.22.112.91  keycloak.local"
```

Vérifier :

```powershell
Select-String "keycloak" "C:\Windows\System32\drivers\etc\hosts"
# Attendu : 172.22.112.91  keycloak.local
```

> L'IP WSL2 peut changer à chaque redémarrage. Vérifier avec `ip addr show eth0` et mettre à jour les deux fichiers si besoin.

> **Important :** Ne pas utiliser un domaine en `.dev` — ce TLD est préchargé HSTS dans tous les navigateurs et force le HTTPS de manière permanente.

---

## 3 — Premier lancement

### Créer les secrets Kubernetes

Les secrets ne sont **jamais** dans le dépôt. À créer une seule fois (ou après chaque reset complet).

```bash
sudo kubectl create namespace iam-system

sudo kubectl create secret generic pg-password \
  --from-literal=password='VOTRE_MOT_DE_PASSE_PG' -n iam-system

sudo kubectl create secret generic redis-password \
  --from-literal=password='VOTRE_MOT_DE_PASSE_REDIS' -n iam-system

sudo kubectl create secret generic keycloak-admin \
  --from-literal=password='VOTRE_MOT_DE_PASSE_ADMIN_KC' -n iam-system
```

Vérifier que les 3 secrets sont présents avant de continuer :

```bash
sudo kubectl get secrets -n iam-system
```

Résultat attendu :

```
NAME             TYPE     DATA   AGE
keycloak-admin   Opaque   1      Xs
pg-password      Opaque   1      Xs
redis-password   Opaque   1      Xs
```

### Déployer la stack

```bash
./scripts/deploy-infra.sh --env local-dev
```

### Surveiller le démarrage

```bash
# État des pods en temps réel
sudo kubectl get pods -n iam-system -w
```

Tous les pods doivent passer en `1/1 Running`. Keycloak met **60-90 secondes** après PostgreSQL.

Vérifier que Keycloak répond :

```bash
curl -v http://keycloak.local/admin/ 2>&1 | grep -E "HTTP/|Location"
# Attendu : HTTP/1.1 302 Found + Location: http://keycloak.local/admin/master/console/
```

Accès depuis le navigateur Windows :

```
http://keycloak.local/admin/

http://keycloak.local/
```

Connexion : `admin` / mot de passe du secret `keycloak-admin`

---

## Logs par service

```bash
# Traefik
sudo kubectl logs -n iam-system deployment/traefik -f

# PostgreSQL
sudo kubectl logs -n iam-system statefulset/postgresql -f

# Redis
sudo kubectl logs -n iam-system deployment/redis -f

# Keycloak
sudo kubectl logs -n iam-system deployment/keycloak -f
```

---

## Arrêter / reprendre les services

### Option 1 — Arrêter k3s entièrement (recommandé)

Suspend tous les pods, données préservées. Équivalent de `docker-compose stop`.

```bash
# Arrêter (WSL2 sans systemd)
sudo k3s-killall.sh

# Arrêter (Linux avec systemd)
sudo systemctl stop k3s

# Reprendre (dans les deux cas)
sudo systemctl start k3s

# Vérifier l'état
sudo systemctl status k3s
```

### Option 2 — Scaler les pods à 0 (arrêt sélectif)

Garde le cluster actif mais stoppe les conteneurs un par un.

```bash
# Arrêter
sudo kubectl scale deployment traefik keycloak redis --replicas=0 -n iam-system
sudo kubectl scale statefulset postgresql --replicas=0 -n iam-system

# Reprendre
sudo kubectl scale deployment traefik keycloak redis --replicas=1 -n iam-system
sudo kubectl scale statefulset postgresql --replicas=1 -n iam-system
```

---

## Réinitialisation

### Reset en conservant les données (recommandé)

Supprime les déploiements mais conserve les volumes PostgreSQL et Redis.

```bash
sudo ./scripts/reset-infra.sh --env local-dev --keep-data
./scripts/deploy-infra.sh --env local-dev
```

### Reset complet (supprime toutes les données)

Supprime le namespace entier **y compris les secrets et les volumes**. Les secrets doivent être recréés avant de redéployer.

```bash
# 1. Reset
sudo ./scripts/reset-infra.sh --env local-dev

# 2. Recréer les secrets
sudo kubectl create namespace iam-system

sudo kubectl create secret generic pg-password \
  --from-literal=password='VOTRE_MOT_DE_PASSE_PG' -n iam-system

sudo kubectl create secret generic redis-password \
  --from-literal=password='VOTRE_MOT_DE_PASSE_REDIS' -n iam-system

sudo kubectl create secret generic keycloak-admin \
  --from-literal=password='VOTRE_MOT_DE_PASSE_ADMIN_KC' -n iam-system

# 3. Vérifier les secrets
sudo kubectl get secrets -n iam-system

# 4. Redéployer
./scripts/deploy-infra.sh --env local-dev
```

---

## Sauvegardes PostgreSQL

Le backup quotidien est géré par un **CronJob Kubernetes** dans le cluster (overlay linux-server).
Pour l'environnement local-dev, utiliser le backup manuel :

```bash
# Backup manuel interactif
./postgres_home/scripts/backup-manual.sh
```

Les backups manuels sont stockés dans `postgres_home/backups/manual/`.
