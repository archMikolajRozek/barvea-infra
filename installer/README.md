# installer/ — stałe instalatora dedyk v2

- `update-manifest.pub.pem` — klucz publiczny Ed25519 `update-manifest-ed25519` z Vault transit (prod, wyciągnięty 2026-11-24 przez `scripts/sign-release-manifest.ts --print-public-key`). deploy-app weryfikuje nim `MANIFEST.sig` nad bajtami `MANIFEST.json` (`openssl pkeyutl -verify -pubin -inkey … -rawin`) i porównuje z `MANIFEST.pub.pem` z paczki. Rotacja klucza = nowy PEM tutaj + bump `INSTALLER_VERSION`.
- `../deploy-app.dedicated.sh` v2 — wdrożenie z paczki na hoście (instalacja / `--update` / `--license`); `../build-release-bundle.sh` v2 — budowa i podpis paczki u nas (barvea-app); `../proxmox/provision-org.sh` — warstwa plików organizacji (dataset + udział + ACL); `../vm102/barvea-compose.sh` → `/usr/local/sbin/barvea-compose` na VM aplikacji. Opis: INSTALATOR-PLAN-2026-11.md §D4.
- `../INSTALLER_VERSION` — minInstallerVersion wpisywany do manifest-input.json przez build-release-bundle.sh; bump przy niekompatybilnej zmianie deploy-app.
