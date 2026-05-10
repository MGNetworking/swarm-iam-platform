# PostgreSQL sur Kubernetes — Guide de compréhension

Ce document explique comment PostgreSQL fonctionne dans l'environnement k3s, en quoi c'est différent de Docker Swarm, et ce que ça change concrètement pour les backups et le dossier `postgres_home/`.

---

## Sommaire

- [La différence fondamentale : Docker Swarm vs Kubernetes](#la-différence-fondamentale-docker-swarm-vs-kubernetes)
  - [Ce que tu faisais avec Docker Swarm](#ce-que-tu-faisais-avec-docker-swarm)
  - [Ce qui change avec Kubernetes](#ce-qui-change-avec-kubernetes)
- [Comment PostgreSQL est déployé en K8s](#comment-postgresql-est-déployé-en-k8s)
  - [Le StatefulSet — pourquoi pas un Deployment ?](#le-statefulset-pourquoi-pas-un-deployment)
    - [D'abord : c'est quoi un Pod ?](#dabord-cest-quoi-un-pod)
    - [Deployment — pour les services sans mémoire](#deployment-pour-les-services-sans-mémoire)
    - [StatefulSet — pour les services avec état](#statefulset-pour-les-services-avec-état)
    - [Analogie concrète](#analogie-concrète)
    - [Résumé du choix dans ce projet](#résumé-du-choix-dans-ce-projet)
  - [Le PVC — le disque persistant](#le-pvc-le-disque-persistant)
  - [La chaîne complète au démarrage](#la-chaîne-complète-au-démarrage)
  - [La communication avec Keycloak](#la-communication-avec-keycloak)
- [Le dossier postgres_home/ — quel rôle maintenant ?](#le-dossier-postgreshome-quel-rôle-maintenant)
  - [backups/ — toujours le répertoire de sortie](#backups-toujours-le-répertoire-de-sortie)
  - [init/ — plus utilisé directement](#init-plus-utilisé-directement)
  - [scripts/ — tous migrés vers kubectl](#scripts-tous-migrés-vers-kubectl)
- [Comment fonctionne un backup (après migration)](#comment-fonctionne-un-backup-après-migration)
  - [Backup quotidien automatique](#backup-quotidien-automatique)
  - [Backup manuel interactif](#backup-manuel-interactif)
- [Restauration — utilisation des scripts](#restauration-utilisation-des-scripts)
- [Commandes utiles au quotidien](#commandes-utiles-au-quotidien)
- [Points d'attention](#points-dattention)

---


## La différence fondamentale : Docker Swarm vs Kubernetes

### Ce que tu faisais avec Docker Swarm

Avec Docker Swarm, PostgreSQL tournait dans un **container Docker standard**. Pour interagir avec lui :

```bash
# Accès direct via l'ID du container
docker exec <container_id> psql -U admin -d kc_db

# Les backups utilisaient docker exec pour appeler pg_dump
docker exec <container_id> pg_dump ...

# Le dossier postgres_home/ était monté comme VOLUME dans le container
# → les backups écrits dans le container apparaissaient directement sur le disque hôte
```

Les secrets étaient des **Docker Secrets**, accessibles dans le container sous `/run/secrets/pg_password`.

### Ce qui change avec Kubernetes

PostgreSQL est maintenant un **Pod** géré par un StatefulSet. Plus de `docker exec` — tout passe par :

```bash
# Équivalent k8s de docker exec
kubectl exec -n iam-system <pod-name> -- psql -U admin -d kc_db

# Ou directement sur le bon pod (avec sélection par label)
kubectl exec -n iam-system \
  $(kubectl get pod -n iam-system -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') \
  -- psql -U admin -d kc_db
```

Les secrets sont des **Kubernetes Secrets**, injectés comme **variables d'environnement** dans le container :

- `$POSTGRES_PASSWORD` (depuis le Secret `pg-password`)
- `$POSTGRES_USER` (depuis le ConfigMap `postgresql-config`)

Il n'y a **plus de volume monté depuis la machine locale**. Le filesystem du pod est totalement isolé — seul le PVC (disque Kubernetes) est persistant.

---

## Comment PostgreSQL est déployé en K8s

### Le StatefulSet — pourquoi pas un Deployment ?

> **Niveau :** notion intermédiaire Kubernetes. Elle n'est pas abordée dans les tutoriels "hello world" mais elle est incontournable dès qu'on déploie une base de données. Pas besoin de la maîtriser parfaitement pour opérer ce projet — il suffit de comprendre pourquoi le choix a été fait.

#### D'abord : c'est quoi un Pod ?

En Kubernetes, un **Pod** est l'unité d'exécution de base — c'est le "container qui tourne". Il est éphémère par nature : si un pod crashe, Kubernetes en recrée un nouveau, et ce nouveau pod a une identité complètement différente (nom, IP, etc.).

Pour gérer des groupes de pods, Kubernetes propose plusieurs types de contrôleurs. Les deux principaux sont **Deployment** et **StatefulSet**.

#### Deployment — pour les services sans mémoire

Un Deployment convient aux services qui n'ont **pas d'état persistant** : un serveur web, une API, un worker. Chaque instance est interchangeable. Si tu as 3 replicas et que l'un crashe, Kubernetes en recrée un nouveau identique — peu importe lequel tourne, le résultat est le même.

Les pods d'un Deployment ont des noms aléatoires et changent à chaque recréation :

```
keycloak-7d9f4b6c8-xk2pq   ← nom généré aléatoirement
keycloak-7d9f4b6c8-m8rvt
```

Traefik, Redis et Keycloak utilisent un Deployment dans ce projet — ils peuvent être recréés sans conséquence.

#### StatefulSet — pour les services avec état

Un StatefulSet convient aux services qui ont besoin de **conserver une identité et des données** entre les redémarrages : bases de données, files de messages, systèmes de cache persistant.

Les pods d'un StatefulSet ont des noms **stables et prévisibles** :

```
postgresql-0   ← toujours ce nom, même après un crash
postgresql-1   ← si on avait 2 replicas
```

La différence cruciale est le lien avec le stockage. Avec un Deployment, si le pod est recréé il peut se retrouver avec un disque différent (ou aucun). Avec un StatefulSet, **le pod `postgresql-0` est toujours attaché au même PVC (Persistent Volume Claim)** (`postgresql-data`), donc aux mêmes données physiques.

#### Analogie concrète

Imagine un serveur de fichiers partagés dans une entreprise :

- Un **Deployment**, c'est comme un agent d'accueil remplaçable : si l'un part en congé, un autre prend le relais avec exactement les mêmes instructions. Peu importe qui c'est.
- Un **StatefulSet**, c'est comme le comptable qui a ses propres classeurs : si tu le remplaces par quelqu'un d'autre, les classeurs (données) ne suivent pas automatiquement. Il faut que le même comptable retrouve ses propres classeurs à son retour.

#### Résumé du choix dans ce projet

```yaml
kind: StatefulSet
metadata:
  name: postgresql
```

Un **StatefulSet** est le type Kubernetes prévu pour les bases de données. Contrairement à un Deployment, il garantit :

| Garantie                            | Deployment                 | StatefulSet                         |
| ----------------------------------- | -------------------------- | ----------------------------------- |
| Nom de pod stable                   | Non (`postgresql-xyz-abc`) | Oui (`postgresql-0`)                |
| Ordre de démarrage                  | Aléatoire                  | Séquentiel                          |
| Ordre d'arrêt                       | Aléatoire                  | Inverse (dernier arrêté en premier) |
| PVC toujours lié à la même instance | Non                        | Oui                                 |

`postgresql-0` est toujours le même pod, avec le même PVC. Si le pod crashe et redémarre, il retrouve exactement ses données — aucune perte.

### Le PVC — le disque persistant

```yaml
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: local-path # (patché par l'overlay linux-server)
```

Le **PVC** (Persistent Volume Claim) est la façon dont un Pod demande du stockage à Kubernetes. Il découple les données du pod :

```
Pod postgresql-0   →   PVC postgresql-data   →   Disque physique sur le nœud
```

Avec `local-path` (StorageClass k3s par défaut), les données sont stockées dans un répertoire sur le disque du VPS, généralement sous `/var/lib/rancher/k3s/storage/`. Ce dossier persiste même si le pod est supprimé et recréé — tant que le PVC existe.

> Si tu supprimes le PVC (`kubectl delete pvc postgresql-data -n iam-system`), **les données sont définitivement perdues**. C'est pourquoi `reset-infra.sh --keep-data` préserve les PVCs.

### La chaîne complète au démarrage

```
1. StatefulSet crée le pod postgresql-0
        ↓
2. Kubernetes monte le PVC postgresql-data dans /var/lib/postgresql/data
        ↓
3. Kubernetes injecte les variables depuis ConfigMap et Secret :
   - POSTGRES_DB=kc_db        (ConfigMap postgresql-config)
   - POSTGRES_USER=admin      (ConfigMap postgresql-config)
   - POSTGRES_PASSWORD=***    (Secret pg-password)
   - PGDATA=/var/lib/postgresql/data/pgdata
        ↓
4. PostgreSQL démarre :
   - Premier démarrage : crée la DB kc_db + l'utilisateur admin
   - Exécute les scripts dans /docker-entrypoint-initdb.d (configmap-init, vide actuellement)
   - Les redémarrages suivants : trouve les données déjà là dans PGDATA → démarre directement
        ↓
5. Service postgresql (ClusterIP) devient accessible sur postgresql:5432
        ↓
6. Keycloak (initContainer) détecte que postgresql:5432 répond → démarre
```

### La communication avec Keycloak

PostgreSQL est exposé via un Service de type **ClusterIP** :

```yaml
kind: Service
metadata:
  name: postgresql
spec:
  type: ClusterIP
  ports:
    - port: 5432
```

`ClusterIP` signifie que le service est uniquement accessible **à l'intérieur du cluster**. Le nom DNS `postgresql` résout automatiquement vers ce service dans le namespace `iam-system`. C'est pourquoi la configuration de Keycloak utilise directement :

```
KC_DB_URL=jdbc:postgresql://postgresql:5432/kc_db
```

PostgreSQL n'est **jamais exposé à l'extérieur** — aucun port 5432 ouvert sur le VPS.

---

## Le dossier postgres_home/ — quel rôle maintenant ?

```
postgres_home/
  backups/    ← TOUJOURS UTILE : destination locale des dumps
  init/       ← PLUS UTILISÉ : remplacé par configmap-init.yaml
  scripts/    ← PARTIELLEMENT MIGRÉ (voir détail ci-dessous)
```

### backups/ — toujours le répertoire de sortie

Les scripts de backup fonctionnent en mode **pipe** : `kubectl exec` lance `pg_dump` dans le pod et redirige le flux compressé vers un fichier **local** (sur la machine qui exécute le script).

```
Pod postgresql-0 (pg_dump)  →  stdout  →  kubectl exec pipe  →  gzip  →  postgres_home/backups/
```

Le dossier `backups/` reste donc le répertoire de sortie des dumps sur ta machine (ou sur le serveur VPS si les scripts y tournent). Les sous-dossiers sont créés automatiquement :

```
postgres_home/backups/
  daily/cluster/    ← backup-daily-cluster.sh (1 fichier .sql.gz par jour, rétention 30j)
  manual/BD/        ← backup-manual.sh mode "base complète"
  manual/schema/    ← backup-manual.sh mode "schéma uniquement"
```

### init/ — plus utilisé directement

En Docker Swarm, ce dossier était probablement monté comme volume dans le container pour fournir des scripts SQL d'initialisation. En Kubernetes, ce rôle est repris par le **ConfigMap `postgresql-init`** (`k8s/base/postgresql/configmap-init.yaml`), monté dans `/docker-entrypoint-initdb.d/` du pod.

`init/` peut être conservé comme emplacement de travail pour préparer des scripts avant de les mettre dans le ConfigMap, mais il n'est plus automatiquement lu par PostgreSQL.

### scripts/ — tous migrés vers kubectl

| Script                     | Mécanisme                               |
| -------------------------- | --------------------------------------- |
| `backup-daily-cluster.sh`  | `kubectl exec` + `pg_dumpall`           |
| `backup-manual.sh`         | `kubectl exec` + `pg_dump`              |
| `restore-daily-cluster.sh` | `kubectl exec` + `kubectl scale`        |
| `restore-manual-db.sh`     | `kubectl exec` + `kubectl scale`        |
| `restore-manual-schema.sh` | `kubectl exec` + `kubectl scale`        |

Tous les scripts acceptent `--env <linux-server|cloud/azure|cloud/aws>`.

---

## Comment fonctionne un backup (après migration)

### Backup quotidien automatique

```bash
./postgres_home/scripts/backup-daily-cluster.sh
# ou avec un environnement spécifique
INFRA_ENV=linux-server ./postgres_home/scripts/backup-daily-cluster.sh
```

Ce que fait le script :

1. Charge `environments/linux-server/.env` et `config.env`
2. Trouve le pod PostgreSQL via son label : `kubectl get pod -l app.kubernetes.io/name=postgresql`
3. Lance `pg_dumpall` dans le pod : `kubectl exec <pod> -- pg_dumpall ...`
4. Compresse le flux (`gzip -9`) et l'écrit dans `postgres_home/backups/daily/cluster/CLUSTER-YYYY-MM-DD.sql.gz`
5. Purge les fichiers de plus de 30 jours (`PG_BACKUP_KEEP_DAYS` dans config.env)

Le fichier produit contient **toutes les bases** du cluster PostgreSQL (sauf les rôles système, option `--no-roles`).

### Backup manuel interactif

```bash
./postgres_home/scripts/backup-manual.sh
```

Propose un menu :

- Liste toutes les bases disponibles (via `psql -c "SELECT datname..."`)
- Choix du mode : base complète (`pg_dump --format=plain`) ou schéma seul (`pg_dump --schema-only`)

---

## Restauration — utilisation des scripts

Tous les scripts de restore sont migrés et fonctionnels. Voir `docs/scripts-guide.md` pour le détail complet.

```bash
# Restauration depuis un backup daily
./postgres_home/scripts/restore-daily-cluster.sh --env linux-server CLUSTER-2025-12-28.sql.gz

# Restauration d'une base complète (données + schéma)
./postgres_home/scripts/restore-manual-db.sh --env linux-server kc_db-2025-12-28_143000.sql.gz

# Restauration du schéma uniquement (structure sans données)
./postgres_home/scripts/restore-manual-schema.sh --env linux-server kc_db-schema-2025-12-28_143000.sql.gz
```

---

## Commandes utiles au quotidien

```bash
# Voir l'état de PostgreSQL
kubectl get pod -n iam-system -l app.kubernetes.io/name=postgresql

# Logs PostgreSQL en temps réel
kubectl logs -n iam-system statefulset/postgresql -f

# Ouvrir un shell dans le pod PostgreSQL
kubectl exec -it -n iam-system postgresql-0 -- sh

# Ouvrir psql directement
kubectl exec -it -n iam-system postgresql-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'

# Lister les bases de données
kubectl exec -n iam-system postgresql-0 -- \
  sh -c 'psql -U "$POSTGRES_USER" -d postgres -c "\l"'

# Voir l'utilisation du PVC (espace disque)
kubectl exec -n iam-system postgresql-0 -- df -h /var/lib/postgresql/data

# Vérifier que le PVC existe et son statut
kubectl get pvc -n iam-system
```

---

## Points d'attention

| Risque                                     | Détail                                                                                                                                                                             |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Suppression du PVC = perte des données** | Un `kubectl delete pvc postgresql-data -n iam-system` est irréversible                                                                                                             |
| **reset-infra.sh sans --keep-data**        | Supprime le namespace entier, donc les PVCs aussi                                                                                                                                  |
| **Backups stockés localement**             | Si les scripts tournent sur le VPS, les backups sont sur le même disque que les données — un crash du VPS perd tout. Idéalement, exfiltrer vers S3 ou rsync vers une autre machine |
| **Pas de haute disponibilité**             | Single-node, single-replica. Si le pod crashe, PostgreSQL est indisponible le temps que K8s le redémarre (~10-30s)                                                                 |
