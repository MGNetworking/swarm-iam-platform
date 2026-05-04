# ADR-0001 — Migration Docker Swarm vers k3s

**Date :** 2026-05-04
**Statut :** Accepté
**Décideurs :** Maxime

---

## Contexte

Le projet déployait Keycloak + PostgreSQL + Redis + Traefik via Docker Swarm sur un NAS
Synology (single-node). L'objectif est de rendre l'infrastructure portable : VPS Linux
bare metal aujourd'hui, cloud managé (Azure AKS / AWS EKS) à l'horizon 2-3 ans.

Docker Swarm ne dispose d'aucune offre managée chez les cloud providers. Tout déploiement
cloud Swarm nécessiterait de gérer soi-même les VMs, sans bénéfice par rapport à un VPS.

## Décision

Migrer vers **k3s** (distribution Kubernetes légère de Rancher) comme unique couche
d'orchestration pour tous les environnements.

## Conséquences

**Positives :**
- Un seul format de manifests (Kubernetes) fonctionne sur VPS k3s et sur AKS/EKS/GKE
- Écosystème standardisé : Kustomize, Helm, ArgoCD, tous compatibles
- k3s s'installe en une commande sur n'importe quel Linux (< 100 MB, 512 MB RAM min)
- Pérennité sur 3+ ans : Kubernetes est le standard industrie de l'orchestration de containers

**Négatives / risques :**
- Réécriture complète des stacks Docker Compose/Swarm en manifests Kubernetes
- Courbe d'apprentissage K8s (objets, RBAC, StorageClasses, Ingress)
- k3s consomme un peu plus de ressources que Swarm à l'idle (~200 MB vs ~50 MB)

## Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Docker Swarm maintenu | Aucun cloud managé, écosystème stagnant |
| Docker Compose seul | Pas d'orchestration multi-node, pas de cloud-portability |
| Kubernetes vanilla (kubeadm) | Trop lourd pour un VPS, k3s est fonctionnellement équivalent |
