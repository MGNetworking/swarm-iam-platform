# Cours Kubernetes — swarm-iam-platform

Cours complet pour comprendre les manifests Kubernetes de ce projet.
Destiné à un développeur qui ne connaît pas K8s.

Chaque module explique un concept avec les fichiers YAML réels du projet et des schémas Mermaid.

## Sommaire

- [Modules](#modules)
- [Commencer ici](#commencer-ici)

---

## Modules

| # | Fichier | Sujet |
|---|---|---|
| 00 | [Introduction](./00-introduction.md) | C'est quoi K8s et k3s, architecture globale |
| 01 | [Namespace](./01-namespace.md) | Isolation des ressources dans `iam-system` |
| 02 | [Pods, Deployments, StatefulSets](./02-pods-deployments-statefulsets.md) | Faire tourner Keycloak, PostgreSQL, Redis, Traefik |
| 03 | [Services et réseau](./03-services-reseau.md) | DNS interne, ClusterIP vs LoadBalancer |
| 04 | [Ingress et Traefik](./04-ingress-traefik.md) | Routage HTTP par domaine, middlewares |
| 05 | [ConfigMaps et Secrets](./05-configmaps-secrets.md) | Configuration et données sensibles |
| 06 | [Stockage PVC](./06-stockage-pvc.md) | Persistance des données PostgreSQL et Redis |
| 07 | [RBAC et ServiceAccount](./07-rbac-serviceaccount.md) | Permissions Traefik sur l'API K8s |
| 08 | [Kustomize](./08-kustomize.md) | Base et overlays multi-environnements |
| 09 | [Architecture complète](./09-architecture-complete.md) | Synthèse, flux complet, récapitulatif |

## Commencer ici

→ [Module 00 — Introduction](./00-introduction.md)
