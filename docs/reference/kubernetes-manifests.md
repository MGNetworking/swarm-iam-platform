# Kubernetes — Manifests et dépendances

---

## Sommaire

- [Pourquoi autant de fichiers YAML différents ?](#pourquoi-autant-de-fichiers-yaml-différents)
- [Pourquoi un ConfigMap plutôt que les valeurs en dur ?](#pourquoi-un-configmap-plutôt-que-les-valeurs-en-dur)
- [Injection de variables — `valueFrom` et résolution au démarrage](#injection-de-variables-valuefrom-et-résolution-au-démarrage)
- [Hiérarchie Kustomize — qui inclut qui](#hiérarchie-kustomize-qui-inclut-qui)
- [Responsabilité de chaque type de fichier](#responsabilité-de-chaque-type-de-fichier)
- [Dépendances entre objets K8s](#dépendances-entre-objets-k8s)
- [Dépendances croisées entre services](#dépendances-croisées-entre-services)
- [Ce que les overlays patchent](#ce-que-les-overlays-patchent)
- [Ordre de création au déploiement](#ordre-de-création-au-déploiement)

---


## Pourquoi autant de fichiers YAML différents ?

Dans `k8s/base/postgresql/` on trouve :

```
postgresql/
├── configmap.yaml
├── configmap-init.yaml
├── statefulset.yaml
├── service.yaml
├── pvc.yaml
└── kustomization.yaml
```

Pourquoi 6 fichiers ? Chaque fichier crée un **objet K8s différent** qui fait **un seul travail**.
Ils ne sont pas interchangeables — ils se complètent.

| Fichier | Objet K8s | Son seul rôle |
|---|---|---|
| `statefulset.yaml` | StatefulSet | Faire tourner le conteneur PostgreSQL |
| `service.yaml` | Service | Créer une adresse réseau stable `postgresql:5432` |
| `pvc.yaml` | PVC | Réserver un disque de 5 Go |
| `configmap.yaml` | ConfigMap | Stocker des variables de configuration |
| `configmap-init.yaml` | ConfigMap | Stocker des scripts SQL à exécuter au démarrage |
| `kustomization.yaml` | Kustomization | Dire à Kustomize quoi inclure dans ce dossier |

Supprimer l'un d'eux, c'est supprimer une fonction entière.

---

## Pourquoi un ConfigMap plutôt que les valeurs en dur ?

Techniquement, tu peux écrire les valeurs directement dans le StatefulSet :

```yaml
# statefulset.yaml SANS ConfigMap
containers:
  - name: postgresql
    env:
      - name: POSTGRES_DB
        value: kc_db      # ← valeur écrite en dur ici
      - name: POSTGRES_USER
        value: admin
```

Mais dans ce projet, `kc_db` est nécessaire dans **deux conteneurs différents** : PostgreSQL ET Keycloak.

**Sans ConfigMap :** la valeur est dupliquée dans `statefulset.yaml` ET `deployment.yaml` de Keycloak.
Renommer la base = modifier **deux fichiers**.

**Avec ConfigMap :** la valeur est à **un seul endroit**. Les deux conteneurs la lisent via `valueFrom` :

```yaml
env:
  - name: POSTGRES_DB
    valueFrom:
      configMapKeyRef:
        name: postgresql-config
        key: DB_NAME        # ← lu depuis le ConfigMap
```

Deuxième avantage : un overlay Kustomize peut patcher le ConfigMap seul pour changer le hostname
sans toucher au Deployment.

---

## Injection de variables — `valueFrom` et résolution au démarrage

Il y a deux façons d'injecter une valeur dans un pod. Les deux coexistent dans ce projet.

**Façon 1 — Valeur écrite directement :**

```yaml
env:
  - name: KC_DB_URL
    value: "jdbc:postgresql://postgresql:5432/keycloak"
```

**Façon 2 — Valeur lue depuis un Secret ou ConfigMap :**

```yaml
env:
  - name: KC_DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: pg-password      ← nom de l'objet Secret K8s
        key: password

  - name: KC_DB_URL
    valueFrom:
      configMapKeyRef:
        name: keycloak-config
        key: KC_DB_URL
```

**Important :** ce n'est pas Kustomize qui résout les `valueFrom`. C'est **k3s lui-même**
au moment où le pod démarre. Si le Secret `pg-password` n'existe pas → le pod reste bloqué en `Pending`.
C'est pourquoi les secrets doivent être créés **avant** le déploiement.

---

## Hiérarchie Kustomize — qui inclut qui

Quand tu exécutes `kubectl apply -k overlays/linux-server/`, Kustomize lit cette chaîne :

```mermaid
graph TB
    OV_LS["overlays/linux-server/kustomization.yaml"]
    OV_AZ["overlays/cloud/azure/kustomization.yaml"]
    OV_AW["overlays/cloud/aws/kustomization.yaml"]
    OV_LD["overlays/local-dev/kustomization.yaml"]

    BASE["base/kustomization.yaml"]

    K_TR["base/traefik/kustomization.yaml"]
    K_PG["base/postgresql/kustomization.yaml"]
    K_RD["base/redis/kustomization.yaml"]
    K_KC["base/keycloak/kustomization.yaml"]

    OV_LS -->|"resources: ../../base"| BASE
    OV_AZ -->|"resources: ../../../base"| BASE
    OV_AW -->|"resources: ../../../base"| BASE
    OV_LD -->|"resources: ../../base"| BASE

    BASE -->|"resources: traefik/"| K_TR
    BASE -->|"resources: postgresql/"| K_PG
    BASE -->|"resources: redis/"| K_RD
    BASE -->|"resources: keycloak/"| K_KC

    K_TR --> TR_FILES["serviceaccount.yaml<br/>clusterrole.yaml<br/>clusterrolebinding.yaml<br/>ingressclass.yaml<br/>configmap-middlewares.yaml<br/>deployment.yaml<br/>service.yaml"]

    K_PG --> PG_FILES["configmap.yaml<br/>configmap-init.yaml<br/>pvc.yaml<br/>statefulset.yaml<br/>service.yaml"]

    K_RD --> RD_FILES["pvc.yaml<br/>deployment.yaml<br/>service.yaml"]

    K_KC --> KC_FILES["configmap.yaml<br/>deployment.yaml<br/>service.yaml<br/>ingress.yaml"]
```

---

## Responsabilité de chaque type de fichier

```mermaid
graph LR
    subgraph kustomize["Kustomize — assemblage"]
        KF["kustomization.yaml<br/>─────────────────<br/>Liste les fichiers à inclure<br/>N'est pas un objet K8s"]
    end

    subgraph reseau["Réseau"]
        NS["namespace.yaml<br/>─────────────────<br/>Crée l'espace isolé iam-system<br/>Prérequis de TOUT le reste"]
        SVC["service.yaml<br/>─────────────────<br/>Crée une adresse DNS stable<br/>vers les Pods"]
        ING["ingress.yaml<br/>─────────────────<br/>Règle de routage<br/>domaine → service"]
        IC["ingressclass.yaml<br/>─────────────────<br/>Déclare Traefik comme<br/>gestionnaire des Ingress"]
    end

    subgraph runtime["Exécution des conteneurs"]
        DEP["deployment.yaml<br/>─────────────────<br/>Conteneur stateless<br/>(Traefik, Keycloak, Redis)"]
        STS["statefulset.yaml<br/>─────────────────<br/>Conteneur stateful<br/>(PostgreSQL)"]
    end

    subgraph config["Configuration"]
        CM["configmap.yaml<br/>─────────────────<br/>Variables injectées<br/>dans les conteneurs"]
        PVC["pvc.yaml<br/>─────────────────<br/>Réserve un disque<br/>persistant"]
    end

    subgraph rbac["Permissions K8s"]
        SA["serviceaccount.yaml<br/>─────────────────<br/>Identité d'un Pod"]
        CR["clusterrole.yaml<br/>─────────────────<br/>Liste des permissions"]
        CRB["clusterrolebinding.yaml<br/>─────────────────<br/>Lie ServiceAccount<br/>à ClusterRole"]
    end
```

---

## Dépendances entre objets K8s

```mermaid
graph TB
    NS["namespace.yaml<br/>(iam-system)"]

    subgraph traefik["Traefik"]
        SA["serviceaccount.yaml"]
        CR["clusterrole.yaml"]
        CRB["clusterrolebinding.yaml"]
        IC["ingressclass.yaml"]
        CM_MW["configmap-middlewares.yaml"]
        DEP_T["deployment.yaml"]
        SVC_T["service.yaml"]
    end

    subgraph postgresql["PostgreSQL"]
        CM_PG["configmap.yaml"]
        CM_PGINIT["configmap-init.yaml"]
        PVC_PG["pvc.yaml"]
        STS_PG["statefulset.yaml"]
        SVC_PG["service.yaml "]
    end

    subgraph redis["Redis"]
        PVC_RD["pvc.yaml"]
        DEP_RD["deployment.yaml"]
        SVC_RD["service.yaml  "]
    end

    subgraph keycloak["Keycloak"]
        CM_KC["configmap.yaml"]
        DEP_KC["deployment.yaml"]
        SVC_KC["service.yaml   "]
        ING["ingress.yaml"]
    end

    subgraph secrets["Secrets — créés manuellement (pas dans Git)"]
        S_PG["Secret: pg-password"]
        S_RD["Secret: redis-password"]
        S_KC["Secret: keycloak-admin"]
    end

    NS --> SA
    NS --> CR
    NS --> IC
    NS --> CM_MW
    NS --> CM_PG
    NS --> CM_PGINIT
    NS --> PVC_PG
    NS --> PVC_RD
    NS --> CM_KC

    SA --> CRB
    CR --> CRB
    CRB --> DEP_T
    CM_MW --> DEP_T
    DEP_T --> SVC_T

    CM_PG --> STS_PG
    CM_PGINIT --> STS_PG
    PVC_PG --> STS_PG
    S_PG --> STS_PG
    STS_PG --> SVC_PG

    PVC_RD --> DEP_RD
    S_RD --> DEP_RD
    DEP_RD --> SVC_RD

    CM_KC --> DEP_KC
    CM_PG --> DEP_KC
    S_PG --> DEP_KC
    S_KC --> DEP_KC
    SVC_PG --> DEP_KC
    SVC_RD --> DEP_KC
    DEP_KC --> SVC_KC

    SVC_KC --> ING
    IC --> ING
    SVC_T -.->|"lit les Ingress via K8s API"| ING
```

---

## Dépendances croisées entre services

Keycloak dépend des trois autres services :

```mermaid
graph LR
    subgraph traefik_b["Traefik"]
        IC2["ingressclass.yaml<br/>(IngressClass: traefik)"]
        SVC_T2["service.yaml<br/>(LoadBalancer :80/:443)"]
    end

    subgraph pg_b["PostgreSQL"]
        CM_PG2["configmap.yaml<br/>(DB_NAME, USER_BD)"]
        SVC_PG2["service.yaml<br/>(ClusterIP: postgresql:5432)"]
    end

    subgraph rd_b["Redis"]
        SVC_RD2["service.yaml<br/>(ClusterIP: redis:6379)"]
    end

    subgraph kc_b["Keycloak"]
        DEP_KC2["deployment.yaml"]
        ING2["ingress.yaml"]
    end

    CM_PG2 -->|"KC_DB_USERNAME = USER_BD"| DEP_KC2
    SVC_PG2 -->|"connexion jdbc:postgresql://postgresql:5432"| DEP_KC2
    SVC_RD2 -->|"connexion redis://redis:6379"| DEP_KC2
    IC2 -->|"ingressClassName: traefik"| ING2
    ING2 -->|"routage domaine → keycloak:8080"| SVC_T2
```

---

## Ce que les overlays patchent

Les overlays ne créent pas de nouveaux objets — ils **modifient** des champs précis des objets de base.

```mermaid
graph LR
    subgraph base_obj["Objets de base/"]
        CM_KC3["keycloak/configmap.yaml<br/>KEYCLOAK_HOSTNAME: keycloak.example.com"]
        ING3["keycloak/ingress.yaml<br/>host: keycloak.example.com"]
        PVC_PG3["postgresql/pvc.yaml<br/>(pas de storageClassName)"]
        PVC_RD3["redis/pvc.yaml<br/>(pas de storageClassName)"]
        DEP_KC3["keycloak/deployment.yaml<br/>args: start"]
    end

    subgraph patches_ls["Patches linux-server"]
        P1["keycloak-hostname.yaml<br/>→ keycloak.monvps.com"]
        P2["keycloak-ingress.yaml<br/>→ host: keycloak.monvps.com"]
        P3["postgresql-storage.yaml<br/>→ storageClassName: local-path"]
        P4["redis-storage.yaml<br/>→ storageClassName: local-path"]
    end

    subgraph patches_ld["Patches local-dev (en plus)"]
        P5["keycloak-args.yaml<br/>→ args: start-dev<br/>→ KC_HOSTNAME_STRICT_HTTPS: false"]
    end

    CM_KC3 -.->|"remplacé par"| P1
    ING3 -.->|"remplacé par"| P2
    PVC_PG3 -.->|"complété par"| P3
    PVC_RD3 -.->|"complété par"| P4
    DEP_KC3 -.->|"remplacé par"| P5
```

---

## Ordre de création au déploiement

K8s crée les objets dans cet ordre logique :

```
1. Namespace (iam-system)
      ↓
2. ServiceAccount + ClusterRole + ClusterRoleBinding (RBAC Traefik)
   ConfigMaps (postgresql-config, keycloak-config, traefik-middlewares, postgresql-init)
   IngressClass (traefik)
   PVCs (postgresql-data, redis-data)
      ↓
3. StatefulSet PostgreSQL   (attend : ConfigMaps + PVC + Secret pg-password)
   Deployment Redis          (attend : PVC + Secret redis-password)
   Deployment Traefik        (attend : ServiceAccount + ConfigMap middlewares)
      ↓
4. Services (postgresql, redis, traefik, keycloak)
      ↓
5. Deployment Keycloak       (attend : Service postgresql + Service redis + Secrets)
      ↓
6. Ingress keycloak          (attend : Service keycloak + IngressClass traefik)
```
