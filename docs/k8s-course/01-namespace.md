# Module 01 — Namespace

## C'est quoi un Namespace ?

Un **Namespace** est une frontière logique dans un cluster Kubernetes. Il te permet de grouper des ressources et de les isoler des autres.

> **Analogie** : imagine un appartement avec des pièces séparées. Chaque pièce (namespace) a ses propres meubles (pods, services…). Quelqu'un dans la cuisine ne peut pas accéder directement aux affaires de la chambre.

Sans namespace, tout serait dans le même espace global `default`, et ça deviendrait vite le chaos sur un cluster qui héberge plusieurs applications.

---

## Sommaire

- [C'est quoi un Namespace ?](#cest-quoi-un-namespace)
- [Pourquoi ce projet utilise un Namespace ?](#pourquoi-ce-projet-utilise-un-namespace)
- [Le fichier du projet](#le-fichier-du-projet)
- [Anatomie d'un fichier YAML Kubernetes](#anatomie-dun-fichier-yaml-kubernetes)
- [Les Labels](#les-labels)
- [Schéma — Un Namespace dans le cluster](#schéma-un-namespace-dans-le-cluster)
- [Commandes utiles](#commandes-utiles)

---


## Pourquoi ce projet utilise un Namespace ?

Tout ce projet tourne dans un seul namespace : **`iam-system`**.

Ça apporte :
- **Isolation** : les ressources IAM sont séparées des autres apps éventuelles du cluster
- **Lisibilité** : `kubectl get pods -n iam-system` ne montre que nos pods
- **Sécurité** : les Secrets (mots de passe) ne sont accessibles que dans ce namespace
- **Nettoyage facile** : `kubectl delete namespace iam-system` supprime tout en une commande

---

## Le fichier du projet

**`k8s/base/namespace.yaml`**

```yaml
apiVersion: v1          # Version de l'API K8s pour cet objet
kind: Namespace         # Type de ressource
metadata:
  name: iam-system      # Le nom du namespace — utilisé dans TOUS les autres fichiers
  labels:
    app.kubernetes.io/managed-by: kustomize  # Label informatif : géré par Kustomize
```

C'est le fichier le plus simple du projet. Trois lignes utiles, et pourtant il est la fondation de tout.

---

## Anatomie d'un fichier YAML Kubernetes

Ce fichier introduit la structure commune à **tous** les fichiers K8s. Ils ont toujours ces 4 champs :

```yaml
apiVersion: v1          # Quelle version de l'API K8s gère cet objet
kind: Namespace         # Quel type d'objet c'est
metadata:               # Informations d'identification
  name: iam-system      #   → son nom unique dans le cluster
spec:                   # (absent ici) La description de l'état désiré
  ...
```

| Champ | Rôle |
|---|---|
| `apiVersion` | Indique à K8s quelle version de l'API utiliser pour lire cet objet |
| `kind` | Le type de ressource (Namespace, Pod, Deployment, Service…) |
| `metadata.name` | L'identifiant unique de la ressource |
| `spec` | La configuration souhaitée (absent pour Namespace car il n'a pas de config) |

---

## Les Labels

```yaml
labels:
  app.kubernetes.io/managed-by: kustomize
```

Les **labels** sont des paires clé/valeur attachées à n'importe quelle ressource. Ils servent à :
- **Filtrer** : `kubectl get pods -l app.kubernetes.io/name=keycloak`
- **Sélectionner** : les Services trouvent leurs Pods grâce aux labels (voir module 03)
- **Organiser** : par convention, on utilise les labels `app.kubernetes.io/*` (standardisés)

Dans ce projet, tous les objets portent au minimum :
- `app.kubernetes.io/name` : le nom du service (`traefik`, `keycloak`, `postgresql`, `redis`)
- `app.kubernetes.io/component` : son rôle (`ingress-controller`, `iam`, `database`, `cache`)

---

## Schéma — Un Namespace dans le cluster

```mermaid
graph TB
    subgraph cluster["Cluster k3s"]
        subgraph default["Namespace: default"]
            A[autres apps...]
        end

        subgraph iam["Namespace: iam-system"]
            T[Pod Traefik]
            K[Pod Keycloak]
            P[Pod PostgreSQL]
            R[Pod Redis]
        end

        subgraph kube["Namespace: kube-system"]
            S[CoreDNS]
            C[kube-proxy]
        end
    end
```

`kube-system` existe toujours — c'est le namespace interne de Kubernetes lui-même (DNS, proxy réseau…). Ne pas y toucher.

---

## Commandes utiles

```bash
# Voir tous les namespaces du cluster
kubectl get namespaces

# Voir toutes les ressources du namespace iam-system
kubectl get all -n iam-system

# Créer le namespace manuellement (normalement fait par deploy-infra.sh)
kubectl apply -f k8s/base/namespace.yaml

# Supprimer TOUT le namespace et toutes ses ressources (destructif !)
kubectl delete namespace iam-system
```

---

> **Prochaine étape →** [Module 02 — Pods, Deployments et StatefulSets](./02-pods-deployments-statefulsets.md)
