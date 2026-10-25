# ot-os-apt

Signed APT repository for **OT-OS**, the Ubuntu 24.04-based distribution for
OT/ICS/SCADA work. Served by GitHub Pages at
**https://janitor-tools.github.io/ot-os-apt/**.

This git repository holds only the **publishing machinery** (workflow, script,
public key). Packages are built and tested in the (private) OT-OS build
repository; no `.deb` file is ever committed here.

## Using the repository

OT-OS installations already have it (package `ot-os-archive-keyring`, which
installs `/etc/apt/sources.list.d/ot-os.sources`). Manual setup on Ubuntu
24.04: see the [repository page](https://janitor-tools.github.io/ot-os-apt/).

| Suite | Content |
|-------|---------|
| `noble` | tagged OT-OS releases |
| `noble-nightly` | every commit on `main`; versions `X~git<date>.<sha>` sort below the release `X` |

Source packages (`.dsc`, tarballs) are published next to the binaries in
`pool/`, so every binary's source is available (GPL).

## Signing key

| | Fingerprint | Expires |
|-|-------------|---------|
| Primary (certify only, kept offline) | `59E1 0148 4CB3 3F6B E34A  EE65 9D66 6CB9 3A41 5504` | 2031-10-24 |
| Signing subkey (CI, `apt-publish` environment) | `0A40 4294 B662 6C58 1838  C1DE 9F16 92FF 2043 2DE1` | 2028-10-24 |

Public key: [`keys/ot-os-archive-keyring.asc`](keys/ot-os-archive-keyring.asc),
also published at the site root. Before the subkey expires, its expiry is
extended with the offline primary key and a new `ot-os-archive-keyring`
package is released; apt rejects repositories signed by an expired key.

## How publishing works

```
ot-linux (private)                       ot-os-apt (this repo, public)
------------------                       -----------------------------
build + lintian + pkg test  --dispatch-> publish.yml
upload artefact "ot-os-packages"          download artefact (run id)
                                          scripts/update-repo.sh:
                                            fetch live repo, verify InRelease
                                            merge (published files immutable)
                                            prune (3 versions / package / suite)
                                            apt-ftparchive + by-hash
                                            sign with subkey, verify
                                          deploy-pages
```

`scripts/update-repo.sh` documents the design in its header.

## One-time setup

1. **Settings → Pages → Source: GitHub Actions.**
2. **Settings → Environments → `apt-publish`** (deployment branches: `main`):
   secrets `APT_SIGNING_KEY`, `APT_SIGNING_PASSPHRASE`,
   `OT_LINUX_ARTIFACT_TOKEN` (fine-grained PAT on `Janitor-tools/ot-linux`,
   *Actions: Read-only*), variable `APT_SIGNING_SUBKEY_FPR`.
3. First deploy: **Actions → publish → Run workflow** with `bootstrap` ticked
   and no run id. This publishes both suites, empty and signed. The OT-OS ISO
   build needs them: live-build runs `apt-get update` with the OT-OS source
   enabled.

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). The packages in the repository
carry their own licenses in `/usr/share/doc/<package>/copyright`.
