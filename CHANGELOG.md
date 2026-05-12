# Changelog

## [4.1.0](https://github.com/MGNetworking/swarm-iam-platform/compare/v4.0.3...v4.1.0) (2026-05-12)


### Features

* **backup:** add rclone off-site backup to NAS and auto-create K8s secrets ([#107](https://github.com/MGNetworking/swarm-iam-platform/issues/107)) ([a7d1ef1](https://github.com/MGNetworking/swarm-iam-platform/commit/a7d1ef1a9fdd6d6b9547a5dbaf65851d732e2ea9))

## [4.0.3](https://github.com/MGNetworking/swarm-iam-platform/compare/v4.0.2...v4.0.3) (2026-05-11)


### Bug Fixes

* **ci:** exclude k8s-course from wiki sync ([#104](https://github.com/MGNetworking/swarm-iam-platform/issues/104)) ([3710367](https://github.com/MGNetworking/swarm-iam-platform/commit/371036716d4575818c1bf0abf4e7938cc515aedb))
* **ci:** improve wiki-sync workflow ([3710367](https://github.com/MGNetworking/swarm-iam-platform/commit/371036716d4575818c1bf0abf4e7938cc515aedb))

## [4.0.2](https://github.com/MGNetworking/swarm-iam-platform/compare/v4.0.1...v4.0.2) (2026-05-11)


### Bug Fixes

* **ci:** add workflow_dispatch to wiki-sync for manual trigger ([2664837](https://github.com/MGNetworking/swarm-iam-platform/commit/2664837e72da65badcb76f5388d2864504c67b51))

## [4.0.1](https://github.com/MGNetworking/swarm-iam-platform/compare/v4.0.0...v4.0.1) (2026-05-11)


### Miscellaneous

* **project:** add MIT license, CODEOWNERS and wiki auto-sync ([c8e0c51](https://github.com/MGNetworking/swarm-iam-platform/commit/c8e0c51fd52d3b9e0cc72abe1c9aebd67841eb6c))
* **project:** add MIT license, CODEOWNERS and wiki sync ([#98](https://github.com/MGNetworking/swarm-iam-platform/issues/98)) ([c8e0c51](https://github.com/MGNetworking/swarm-iam-platform/commit/c8e0c51fd52d3b9e0cc72abe1c9aebd67841eb6c))

## [4.0.0](https://github.com/MGNetworking/swarm-iam-platform/compare/v3.0.1...v4.0.0) (2026-05-11)


### Features

* **k8s:** migrate platform from Docker Swarm to k3s with Kustomize ([935b83e](https://github.com/MGNetworking/swarm-iam-platform/commit/935b83e4e3c6258b2b204f98b72de6607d38342c))
* **k8s:** migrate platform to k3s with Kustomize and restructure docs ([#93](https://github.com/MGNetworking/swarm-iam-platform/issues/93)) ([#94](https://github.com/MGNetworking/swarm-iam-platform/issues/94)) ([935b83e](https://github.com/MGNetworking/swarm-iam-platform/commit/935b83e4e3c6258b2b204f98b72de6607d38342c))


### Bug Fixes

* **ci:** upgrade release-please-action to v5 (Node.js 24) ([bef3ee9](https://github.com/MGNetworking/swarm-iam-platform/commit/bef3ee9f06b7738df860bd520807dcf493b73bb1))
* **ci:** upgrade release-please-action to v5 (Node.js 24) ([d5a1db8](https://github.com/MGNetworking/swarm-iam-platform/commit/d5a1db8255b72f18049098f0e7b1371e9e19f772))

## [3.0.1](https://github.com/MGNetworking/swarm-iam-platform/compare/v3.0.0...v3.0.1) (2026-03-30)


### Bug Fixes

* **ci:** exclude third-party wait-for-it.sh from shellcheck ([c2b05bf](https://github.com/MGNetworking/swarm-iam-platform/commit/c2b05bf2f9e37ca3a67bc02d00ab88bf0003eb4f))
* **ci:** fix shellcheck and yamllint errors ([2f8644a](https://github.com/MGNetworking/swarm-iam-platform/commit/2f8644a70071effbc2d21dbd5727e39425589ab6))
* **ci:** fix shellcheck warnings and yamllint errors across all scripts ([7cc16d8](https://github.com/MGNetworking/swarm-iam-platform/commit/7cc16d8bcb11f3d6080beffb5cf437e39a12f0d1))


### CI / Automation

* add GitHub Actions workflows for shellcheck, yamllint and release-please ([5901417](https://github.com/MGNetworking/swarm-iam-platform/commit/5901417febc964cb56de415e7b58974a885da9f3))


### Miscellaneous

* add CLAUDE.md with project technical context for Claude Code ([92a41d0](https://github.com/MGNetworking/swarm-iam-platform/commit/92a41d054e1e5d496a66f28de9def452e0e01333))
* add OBJECTIVES.md to gitignore and update CLAUDE.md formatting ([0604c32](https://github.com/MGNetworking/swarm-iam-platform/commit/0604c32789031b06211417e4fe338e83dffb2364))
* configure release-please with simple release type and version 0.1.0 ([c18c02d](https://github.com/MGNetworking/swarm-iam-platform/commit/c18c02dcf41c500618e276acd8e6932378dec0fd))
* extend .gitattributes to normalize line endings for yml, yaml, md, json, manifest ([4f6ac91](https://github.com/MGNetworking/swarm-iam-platform/commit/4f6ac9163a1cd12a8664f5a70158395735bb6d89))
* mark infrastructure scripts as executable ([440b4ec](https://github.com/MGNetworking/swarm-iam-platform/commit/440b4eceabe01ee764052e972cbee40cdd066d88))
* set release baseline to v3.0.0 ([14b4450](https://github.com/MGNetworking/swarm-iam-platform/commit/14b4450bc192cb01a286f67af4d0001824ee10d5))
* set release version to 3.0.0 to align with existing tags ([b09fb4a](https://github.com/MGNetworking/swarm-iam-platform/commit/b09fb4abca7544b80eb6a18cf152bdc0233d540b))
* **setup:** project configuration — git conventions, CI, Release Please and documentation ([927af2a](https://github.com/MGNetworking/swarm-iam-platform/commit/927af2ad2ce99b42a52d7f865bb9aef59ff7ae75))
* **setup:** project configuration — git conventions, CI, Release Please and documentation ([927af2a](https://github.com/MGNetworking/swarm-iam-platform/commit/927af2ad2ce99b42a52d7f865bb9aef59ff7ae75))
