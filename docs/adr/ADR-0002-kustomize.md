# ADR-0002 — Kustomize comme gestionnaire de configuration Kubernetes

**Date :** 2026-05-04
**Statut :** Accepté
**Décideurs :** Maxime

---

## Contexte

Les manifests Kubernetes doivent fonctionner sur plusieurs environnements avec des
différences de configuration : StorageClass, limites de ressources, hostnames, DNS.
Il faut un mécanisme pour éviter la duplication des fichiers YAML tout en permettant
des variations par environnement.

## Décision

Utiliser **Kustomize** avec une structure `base/` + `overlays/<env>/`.

- `k8s/base/` contient les manifests communs à tous les environnements
- `k8s/overlays/<env>/` contient les patches spécifiques à chaque environnement

## Conséquences

**Positives :**
- Intégré nativement dans `kubectl` depuis la v1.14 (zéro dépendance à installer)
- Les manifests base restent du YAML Kubernetes pur (lisible, auditable)
- Les patches sont minimaux : on ne redéfinit que ce qui change par env
- Chemin naturel vers Helm si la complexité augmente (les bases sont réutilisables)

**Négatives / risques :**
- Moins de fonctionnalités que Helm (pas de templating avancé, pas de hooks)
- Si les environnements cloud nécessitent des objets radicalement différents,
  les overlays peuvent devenir complexes

## Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Manifests bruts par env | Duplication massive, maintenabilité nulle |
| Helm charts custom | Overkill à ce stade, ajoute la syntaxe Go template à apprendre |
| Helm charts communautaires | Abstraction trop élevée, perd la valeur pédagogique et de contrôle |
