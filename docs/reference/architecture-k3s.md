# Architecture k3s — swarm-iam-platform

Vue d'ensemble technique du fonctionnement de la plateforme IAM sur k3s.

---

## Sommaire

- [Stack déployée](#stack-déployée)
- [Pourquoi k3s](#pourquoi-k3s)
- [Composants — fonctionnement détaillé](#composants-fonctionnement-détaillé)
  - [Traefik — la porte d'entrée](#traefik-la-porte-dentrée)
  - [PostgreSQL — StatefulSet](#postgresql-statefulset)
  - [Redis — cache de sessions](#redis-cache-de-sessions)
  - [Keycloak — le cœur IAM](#keycloak-le-cœur-iam)
- [Communication interne — DNS Kubernetes](#communication-interne-dns-kubernetes)
- [Kustomize — adaptation multi-environnements](#kustomize-adaptation-multi-environnements)
  - [Ce qui est patché par overlay](#ce-qui-est-patché-par-overlay)
  - [Exemple de patch (linux-server)](#exemple-de-patch-linux-server)
- [Secrets Kubernetes](#secrets-kubernetes)
- [Ressources allouées](#ressources-allouées)
- [Limites et axes d'évolution](#limites-et-axes-dévolution)

---


## Stack déployée

| Service    | Version   | Rôle                                                  |
| ---------- | --------- | ----------------------------------------------------- |
| k3s        | stable    | Orchestrateur Kubernetes léger (single-node)          |
| Traefik    | v3.1      | Ingress Controller / reverse proxy                    |
| Keycloak   | 26.0      | SSO / IAM — authentification et gestion des identités |
| PostgreSQL | 17-alpine | Base de données de Keycloak                           |
| Redis      | 7-alpine  | Cache de sessions (512 MB max)                        |

Tous les composants s'exécutent dans le namespace `iam-system`.

---

## Pourquoi k3s

k3s est une distribution Kubernetes allégée, conçue pour les VPS single-node. L'installation requiert un flag spécifique :

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
```

Le `--disable=traefik` est obligatoire : k3s embarque Traefik v2 par défaut. Ce projet déploie sa propre instance **Traefik v3.1** dans `iam-system` — sans ce flag, les deux instances se marcheraient dessus sur les ports 80/443.

k3s intègre également un contrôleur LoadBalancer léger (**Klipper**) qui mappe automatiquement les Services de type `LoadBalancer` sur l'IP du nœud hôte.

---

## Composants — fonctionnement détaillé

### Traefik — la porte d'entrée

Traefik est le seul composant exposé à l'extérieur du cluster. Son déploiement nécessite plusieurs ressources Kubernetes pour fonctionner :

```
ServiceAccount traefik
    ↓ lié à
ClusterRole traefik       ← droits de lecture sur services/endpoints/ingresses
    ↓ via
ClusterRoleBinding traefik
    ↓ utilisé par
Deployment traefik        (1 replica, image traefik:v3.1)
    ↓ exposé par
Service traefik           (type: LoadBalancer, ports 80 et 443)
    ↓ déclaré comme
IngressClass "traefik"
```

Le `ClusterRole` accorde à Traefik le droit de **lire** les ressources `services`, `endpoints`, `secrets`, `ingresses` et `ingressclasses` du cluster. C'est ce mécanisme RBAC (Role-Based Access Control) qui lui permet de découvrir et router dynamiquement les requêtes sans configuration statique.

Le Service `LoadBalancer` est pris en charge par Klipper (inclus dans k3s) : les ports 80 et 443 du nœud sont automatiquement forwardés vers le pod Traefik.

Traefik démarre avec `--api.dashboard=false` — le dashboard est désactivé en production.

---

### PostgreSQL — StatefulSet

```
ConfigMap postgresql-config   →  DB_NAME=kc_db, USER_BD=admin
Secret    pg-password          →  POSTGRES_PASSWORD
ConfigMap postgresql-init      →  scripts SQL exécutés au premier boot (vide par défaut)
PVC       postgresql-data      →  5 Gi (storageClass patchée par l'overlay)
    ↓ tout consommé par
StatefulSet postgresql         (postgres:17-alpine, port 5432)
    ↓ exposé par
Service postgresql             (type: ClusterIP)
```

PostgreSQL est déployé en **StatefulSet** et non en Deployment. Ce choix garantit :

- Une identité réseau stable (`postgresql-0`) qui ne change pas entre les redémarrages
- Un ordre déterministe d'arrêt et de démarrage, essentiel pour une base de données

Les health checks utilisent `pg_isready` : si PostgreSQL ne répond plus, Kubernetes le redémarre automatiquement. La `livenessProbe` attend 30 secondes avant le premier check (`initialDelaySeconds: 30`) pour laisser le temps à PostgreSQL de s'initialiser.

Les données sont stockées dans `/var/lib/postgresql/data/pgdata` sur le PVC, garantissant la persistance entre les redémarrages de pod.

---

### Redis — cache de sessions

```
Secret redis-password   →  REDIS_PASSWORD
PVC    redis-data        →  1 Gi
    ↓ consommés par
Deployment redis         (redis:7-alpine, port 6379)
    ↓ exposé par
Service redis            (type: ClusterIP)
```

Redis est lancé avec des arguments de configuration directement dans la commande :

| Argument             | Valeur              | Effet                                     |
| -------------------- | ------------------- | ----------------------------------------- |
| `--maxmemory`        | `512mb`             | Plafond dur de mémoire                    |
| `--maxmemory-policy` | `allkeys-lru`       | Éviction LRU quand le plafond est atteint |
| `--appendonly`       | `yes`               | Persistance AOF activée sur le PVC        |
| `--requirepass`      | `$(REDIS_PASSWORD)` | Auth obligatoire via le Secret            |

Redis est un Deployment (et non un StatefulSet) car c'est un cache : en cas de perte des données, Keycloak recrée les sessions. La persistance AOF est néanmoins activée pour éviter les pertes sur un simple redémarrage de pod.

> **Note :** Dans la configuration actuelle, Redis est présent dans la stack mais **non câblé à Keycloak**. Le deployment Keycloak ne contient pas de variables `KC_CACHE_*` ou `KC_REMOTE_STORE_*`. C'est un axe d'évolution prévu.

---

### Keycloak — le cœur IAM

Keycloak est le composant le plus complexe. Il dépend explicitement de PostgreSQL via un `initContainer` :

```
initContainer wait-for-postgresql
    → boucle: nc -z postgresql 5432
    → attend que PostgreSQL accepte des connexions TCP
    ↓ seulement quand PostgreSQL est prêt
Container keycloak             (quay.io/keycloak/keycloak:26.0)
    ↓ exposé par
Service keycloak               (type: ClusterIP, port 8080)
    ↓ routé par
Ingress keycloak               (ingressClassName: traefik, host patché par overlay)
```

Variables d'environnement clés du container :

| Variable                      | Source                        | Valeur / Rôle                                        |
| ----------------------------- | ----------------------------- | ---------------------------------------------------- |
| `KC_DB`                       | hardcodé                      | `postgres`                                           |
| `KC_DB_URL`                   | hardcodé                      | `jdbc:postgresql://postgresql:5432/kc_db`            |
| `KC_DB_USERNAME`              | ConfigMap `postgresql-config` | `admin`                                              |
| `KC_DB_PASSWORD`              | Secret `pg-password`          | mot de passe PostgreSQL                              |
| `KC_HOSTNAME`                 | ConfigMap `keycloak-config`   | hostname patché par overlay                          |
| `KC_HTTP_ENABLED`             | hardcodé                      | `true` — TLS délégué à Traefik                       |
| `KC_PROXY_HEADERS`            | hardcodé                      | `xforwarded` — obligatoire derrière Traefik          |
| `KC_HEALTH_ENABLED`           | hardcodé                      | `true` — endpoints `/health/live` et `/health/ready` |
| `KC_BOOTSTRAP_ADMIN_PASSWORD` | Secret `keycloak-admin`       | mot de passe admin initial                           |

`KC_PROXY_HEADERS=xforwarded` est indispensable : sans ce flag, Keycloak rejette les requêtes qui arrivent via un reverse proxy et construirait des URLs de redirect incorrectes.

Les health checks pointent vers `/health/live` et `/health/ready` avec `initialDelaySeconds: 60/90` — Keycloak met environ **60-90 secondes** à démarrer complètement.

---

## Communication interne — DNS Kubernetes

Tous les services communiquent via le **DNS interne Kubernetes**, sans jamais sortir du cluster :

```
Internet
    ↓ port 80/443
Service traefik (LoadBalancer)
    ↓ Klipper (k3s)
Pod traefik
    ↓ Ingress rule: keycloak.mondomaine.com → keycloak:8080
Service keycloak (ClusterIP)
    ↓
Pod keycloak
    ↓ jdbc:postgresql://postgresql:5432/kc_db
Service postgresql (ClusterIP)
    ↓
Pod postgresql
```

Le nom DNS `postgresql` résout automatiquement vers l'IP ClusterIP du Service `postgresql` dans le namespace `iam-system`. C'est le DNS Kubernetes natif (`kube-dns` / `CoreDNS`) qui gère cette résolution.

---

## Kustomize — adaptation multi-environnements

La structure `base/` contient tous les manifests avec des valeurs génériques. Les overlays patchent **uniquement ce qui diffère** par environnement.

```
k8s/
  base/               ← manifests communs (identiques sur tous les environnements)
  overlays/
    linux-server/     ← VPS bare metal (Hetzner, OVH, etc.)
    cloud/azure/      ← AKS (Azure Kubernetes Service)
    cloud/aws/        ← EKS (Elastic Kubernetes Service)
```

### Ce qui est patché par overlay

| Ressource patchée                      | linux-server | cloud/azure       | cloud/aws       |
| -------------------------------------- | ------------ | ----------------- | --------------- |
| PVC PostgreSQL — `storageClassName`    | `local-path` | `managed-csi`     | `gp2`           |
| PVC Redis — `storageClassName`         | `local-path` | `managed-csi`     | `gp2`           |
| ConfigMap `keycloak-config` — hostname | ton-vps.com  | ton-aks.azure.com | ton-eks.aws.com |
| Ingress `keycloak` — host              | ton-vps.com  | ton-aks.azure.com | ton-eks.aws.com |

`local-path` est la StorageClass native de k3s : elle provisionne du stockage local directement sur le disque du nœud. Sur cloud, les StorageClasses `managed-csi` (Azure) et `gp2` (AWS) provisionnent des disques managés détachables.

### Exemple de patch (linux-server)

```yaml
# overlays/linux-server/patches/postgresql-storage.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
spec:
  storageClassName: local-path
```

Kustomize fusionne ce patch avec le PVC de la `base/` — seul le champ `storageClassName` est surchargé.

---

## Secrets Kubernetes

Les secrets ne sont **jamais dans le repo**. Ils sont créés manuellement sur le cluster avant tout déploiement :

```bash
kubectl create secret generic pg-password \
  --from-literal=password='MOT_DE_PASSE_PG' -n iam-system

kubectl create secret generic redis-password \
  --from-literal=password='MOT_DE_PASSE_REDIS' -n iam-system

kubectl create secret generic keycloak-admin \
  --from-literal=password='MOT_DE_PASSE_ADMIN_KC' -n iam-system
```

Le script `secrets/check-secrets.sh --env <env>` vérifie que les trois secrets sont présents avant déploiement.

---

## Ressources allouées

| Service    | CPU request | Mémoire request | Mémoire limit |
| ---------- | ----------- | --------------- | ------------- |
| Traefik    | 100m        | 64 Mi           | 256 Mi        |
| PostgreSQL | 100m        | 256 Mi          | 512 Mi        |
| Redis      | 100m        | 128 Mi          | 600 Mi        |
| Keycloak   | 200m        | 512 Mi          | 1 Gi          |
| **Total**  | **500m**    | **960 Mi**      | **~2.4 Gi**   |

Un VPS avec **2 vCPU / 2 GB RAM** minimum est requis.

---

## Limites et axes d'évolution

| Limitation                  | Impact actuel                            | Évolution possible                                  |
| --------------------------- | ---------------------------------------- | --------------------------------------------------- |
| TLS absent                  | Keycloak exposé en HTTP seulement        | Ajouter cert-manager + ClusterIssuer Let's Encrypt  |
| Redis non câblé à Keycloak  | Pas de cache de sessions distribué       | Configurer `KC_CACHE_REMOTE_*` dans le deployment   |
| `configmap-init.yaml` vide  | Pas de script SQL d'init custom          | Ajouter des scripts de création de schémas/rôles    |
| Dashboard Traefik désactivé | Pas de visibilité sur les routes actives | Activer `--api.dashboard=true` avec auth middleware |
| PostgreSQL single-node      | Pas de haute disponibilité               | Patroni ou CloudNativePG pour HA                    |
| Pas de monitoring           | Pas d'alerting sur l'état des pods       | Ajouter Prometheus + Alertmanager                   |
