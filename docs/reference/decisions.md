# Décisions d'architecture

Historique des choix techniques structurants du projet.

---

## Sommaire

- [1. Migration Docker Swarm vers k3s](#1-migration-docker-swarm-vers-k3s)
  - [Pourquoi cette migration](#pourquoi-cette-migration)
  - [Ce qui a changé](#ce-qui-a-changé)
  - [Choix : k3s](#choix-k3s)
  - [Avantages](#avantages)
  - [Inconvénients et risques](#inconvénients-et-risques)
  - [Alternatives rejetées](#alternatives-rejetées)
- [2. Kustomize comme gestionnaire de configuration](#2-kustomize-comme-gestionnaire-de-configuration)
  - [Problème résolu](#problème-résolu)
  - [Structure adoptée](#structure-adoptée)
  - [Pourquoi Kustomize plutôt que Helm](#pourquoi-kustomize-plutôt-que-helm)
  - [Limites](#limites)
  - [Alternatives rejetées](#alternatives-rejetées)

---


## 1. Migration Docker Swarm vers k3s

**Date :** 2026-05-04

### Pourquoi cette migration

Le projet déployait Keycloak + PostgreSQL + Redis + Traefik via Docker Swarm sur un NAS
Synology (single-node). L'objectif est de rendre l'infrastructure portable : VPS Linux
bare metal aujourd'hui, cloud managé (Azure AKS / AWS EKS) à l'horizon 2-3 ans.

Docker Swarm ne dispose d'aucune offre managée chez les cloud providers. Tout déploiement
cloud Swarm nécessiterait de gérer soi-même les VMs, sans bénéfice par rapport à un VPS.

### Ce qui a changé

- Les stacks Docker Compose/Swarm (`environments/homeLab/`) ont été supprimées
- Remplacées par des manifests Kubernetes dans `k8s/base/` et `k8s/overlays/`
- Les scripts ont été réécrits pour `kubectl` (deploy, ensure, restart, reset)
- Les sauvegardes PostgreSQL passent par `kubectl exec` au lieu de volumes montés

### Choix : k3s

**k3s** est une distribution Kubernetes légère de Rancher :
- S'installe en une commande sur n'importe quel Linux
- Consomme moins de 100 MB de stockage, 512 MB RAM minimum
- Fonctionnellement équivalent à Kubernetes vanilla (kubeadm) pour ce projet

Les manifests produits fonctionnent sur k3s, AKS et EKS sans modification —
seuls les overlays Kustomize varient par environnement.

### Avantages

- Un seul format de manifests fonctionne sur VPS k3s et sur AKS/EKS/GKE
- Écosystème standardisé : Kustomize, Helm, ArgoCD, tous compatibles nativement
- Pérennité sur 3+ ans : Kubernetes est le standard industrie

### Inconvénients et risques

- Courbe d'apprentissage K8s (objets, RBAC, StorageClasses, Ingress)
- k3s consomme un peu plus de ressources que Swarm à l'idle (~200 MB vs ~50 MB)

### Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Docker Swarm maintenu | Aucun cloud managé, écosystème stagnant |
| Docker Compose seul | Pas d'orchestration multi-node, pas de cloud-portability |
| Kubernetes vanilla (kubeadm) | Trop lourd pour un VPS, k3s est fonctionnellement équivalent |

---

## 2. Kustomize comme gestionnaire de configuration

**Date :** 2026-05-04

### Problème résolu

Les manifests Kubernetes doivent fonctionner sur plusieurs environnements avec des
différences de configuration : StorageClass, limites de ressources, hostnames, DNS.
Il faut un mécanisme pour éviter la duplication des fichiers YAML tout en permettant
des variations par environnement.

### Structure adoptée

Kustomize avec une organisation `base/` + `overlays/<env>/` :

```
k8s/
  base/               ← manifests communs à tous les environnements
  overlays/
    linux-server/     ← patches spécifiques au VPS bare metal
    cloud/azure/      ← patches spécifiques à AKS
    cloud/aws/        ← patches spécifiques à EKS
```

`k8s/base/` contient les ressources communes (Deployment, Service, ConfigMap, Ingress).
`k8s/overlays/<env>/` contient uniquement ce qui change par environnement.

Un patch ne redéfinit que les champs qui changent. Tout le reste est hérité de `base/`.

### Pourquoi Kustomize plutôt que Helm

- Intégré nativement dans `kubectl` depuis la v1.14 — zéro dépendance à installer
- Les manifests `base/` restent du YAML Kubernetes pur (lisible, auditable)
- Les patches sont minimaux : on ne redéfinit que ce qui change par environnement
- Chemin naturel vers Helm si la complexité augmente (les bases sont réutilisables)

### Limites

- Moins de fonctionnalités que Helm (pas de templating avancé, pas de hooks)
- Si les environnements cloud nécessitent des objets radicalement différents,
  les overlays peuvent devenir complexes à maintenir

### Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Manifests bruts par environnement | Duplication massive, maintenabilité nulle |
| Helm charts custom | Overkill à ce stade, ajoute la syntaxe Go template à apprendre |
| Helm charts communautaires | Abstraction trop élevée, perd le contrôle fin |
