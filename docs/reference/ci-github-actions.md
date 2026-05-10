# CI — GitHub Actions

Ce document explique le pipeline d'intégration continue du projet, défini dans `.github/workflows/ci.yml`.

---

## Sommaire

- [Déclenchement](#déclenchement)
- [Les 3 jobs](#les-3-jobs)
  - [Job 1 — Shellcheck : lint des scripts Bash](#job-1-shellcheck-lint-des-scripts-bash)
  - [Job 2 — Yamllint : validation des fichiers YAML](#job-2-yamllint-validation-des-fichiers-yaml)
  - [Job 3 — Kubeconform : validation des manifests Kubernetes](#job-3-kubeconform-validation-des-manifests-kubernetes)
- [Pourquoi les `kustomization.yaml` sont exclus](#pourquoi-les-kustomizationyaml-sont-exclus)
- [Résumé visuel](#résumé-visuel)

---


## Déclenchement

La CI s'exécute automatiquement sur GitHub à chaque :

- **push** sur les branches `main` ou `develop`
- **pull request** ciblant `main` ou `develop`

Elle sert de filet de sécurité : un problème détecté ici bloque le merge avant que du code cassé n'atteigne les branches protégées.

---

## Les 3 jobs

### Job 1 — Shellcheck : lint des scripts Bash

```yaml
find . -name "*.sh" -not -path "./.git/*" \
  | xargs shellcheck --severity=warning
```

Analyse tous les fichiers `.sh` du projet avec [shellcheck](https://www.shellcheck.net/), un outil de linting statique pour Bash. Il détecte les erreurs et mauvaises pratiques sans exécuter les scripts.

Exemples de ce qu'il signale :

| Problème | Mauvais | Correct |
|---|---|---|
| Variable non quotée | `echo $VAR` | `echo "$VAR"` |
| `cd` sans vérification | `cd /tmp; rm -rf *` | `cd /tmp || exit 1; rm -rf *` |
| Comparaison de chaînes | `[ $A == $B ]` | `[ "$A" = "$B" ]` |
| Masquage d'erreur silencieux | `CMD &> /dev/null` | vérifier le code retour |

Seuil : `--severity=warning` — les avertissements font échouer la CI, pas seulement les erreurs critiques.

---

### Job 2 — Yamllint : validation des fichiers YAML

```yaml
find . -name "*.yml" -not -path "./.git/*" \
  | xargs yamllint -d "{extends: relaxed, rules: {line-length: {max: 120}}}"
```

Vérifie que tous les fichiers `.yml` sont syntaxiquement valides et correctement formatés. La configuration utilisée est `relaxed` (permissive) avec une seule contrainte ajoutée : les lignes sont limitées à **120 caractères**.

Ce job protège des erreurs YAML invisibles à l'œil nu : une indentation d'un espace en trop peut changer complètement la signification d'un manifest Kubernetes sans déclencher d'erreur apparente.

---

### Job 3 — Kubeconform : validation des manifests Kubernetes

```yaml
find k8s/base -name "*.yaml" -not -name "kustomization.yaml" \
  | xargs kubeconform -strict -ignore-missing-schemas \
      -kubernetes-version 1.28.0 -summary
```

Valide les manifests Kubernetes contre le **schéma officiel de Kubernetes 1.28**. C'est le job le plus important pour ce projet.

Il détecte :
- Un champ inexistant dans une ressource (`apiVersions` au lieu de `apiVersion`)
- Un type de valeur incorrect (`replicas: "1"` au lieu de `replicas: 1`)
- Une ressource Kubernetes mal formée

Il tourne sur deux périmètres distincts :

| Périmètre | Chemin |
|---|---|
| Manifests de base | `k8s/base/**/*.yaml` (hors `kustomization.yaml`) |
| Patches VPS | `k8s/overlays/linux-server/patches/*.yaml` |

> **Angle mort :** les overlays `cloud/azure` et `cloud/aws` ne sont pas validés par la CI. Les patches qu'ils contiennent ne sont pas vérifiés automatiquement.

---

## Pourquoi les `kustomization.yaml` sont exclus

```yaml
-not -name "kustomization.yaml"
```

Les fichiers `kustomization.yaml` utilisent un schéma propre à Kustomize, pas un schéma Kubernetes standard. Kubeconform ne sait pas les valider et les rejette en erreur. Ils sont donc explicitement exclus.

---

## Résumé visuel

```
Push / PR → main ou develop
        ↓
┌──────────────────────────────────────────┐
│  Job 1 : shellcheck                      │
│  Tous les .sh → syntaxe + bonnes pratiqu │
└──────────────────────────────────────────┘
┌──────────────────────────────────────────┐
│  Job 2 : yamllint                        │
│  Tous les .yml → syntaxe YAML valide     │
└──────────────────────────────────────────┘
┌──────────────────────────────────────────┐
│  Job 3 : kubeconform                     │
│  k8s/base/ + overlays/linux-server/      │
│  → conformité schéma Kubernetes 1.28     │
└──────────────────────────────────────────┘
        ↓
  Tout vert → merge autorisé
  Une erreur → merge bloqué
```
