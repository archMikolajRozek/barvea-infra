# Instalator v2 (dedyk / appliance / DR) — plan prac, start 2026-11-24

Decyzja Miko 2026-11-23: kolejka infry pusta → budujemy nowy instalator TERAZ, nie po milestone.
Cel: **od gołego Proxmoxa do działającej instancji z aktualną appką, w pełni przetestowane na VM 999**,
i dalsze zmiany appki = nowy bundle + `deploy-app`, bez dotykania instalatora.

## 0. Punkt wyjścia (co jest, co zgniło od lipca)
| Element | Stan | Problem |
|---|---|---|
| `wizard.sh` | napisany 07-14, NIETESTOWANY | brak: pule fast/bulk, backup-skip + backup-enable, ekran Vault, admin, handover, moduł Drive, nazwy hostów |
| `bootstrap.sh` | E2E na VM 999 07-14 (preset staging) | brak wszystkiego z 09–11: dnsmasq tunelu, veto Samby, ClamAV, unattended `20auto-upgrades`, pule, VM 102 8c/32G, Caddy bez Cloudflare, admin host, restic |
| `deploy-app.dedicated.sh` | napisany, NIGDY nieuruchomiony | env.template z lipca (dziś ~110 zmiennych w `.env.example`), compose dedyka ma app/dwg/office/pcp/collab + postgres/redis, BRAK ifc-clash/ifc-extractor, nadal minio (K1: out); env.template NIE ISTNIEJE; brak sekretów nowych (TOTP, MTLS, IFC_*, COLLAB_*) |
| `build-release-bundle.sh` | 1 bundle zbudowany 07-14 | tylko app+dwg+postgres+redis(+minio — K1: MinIO wypada) |
| `build-offline-assets.sh` | eksperymentalny | integracja air-gap (mirror apt) nieskończona |
| VM 999 staging (nested PVE, 12 G, 10.10.0.99) | migawka `czysty-bootstrap` | 12 G za mało na VM 102 jak prod → preset staging z małymi gośćmi |
| `INSTALL-DEDYK.md` | runbook z lipca | do przepisania po v2 |

## 1. Etapy (każdy = 1 wieczór, osobny commit, bez dotykania proda)

### D1 — Inwentarz różnic prod ↔ IaC + decyzje (24.11)
- Diff: `.env.example` (prod) vs `app/deploy/dedicated/env.template` → lista zmiennych do szablonu dedyka, podział: generowane / z kreatora / stałe / puste w air-gap.
- Diff: `docker-compose.yml` (prod: 8 usług) vs `app/deploy/dedicated/docker-compose.dedicated.yml` → prośba do APP: + ifc-clash, ifc-extractor, profile per moduł, MinIO out, env.template (brak).
- Diff: bootstrap vs runbooki 09–11 (HARDENING, DRIVE-DNS-VETO, KOLIZJE, BEZPIECZENSTWO-ETAP2, MOBILE) → lista kroków do dopisania.
- Decyzje Miko (patrz §3) → zapis w tym pliku.

### D2 — `wizard.sh` v2 (ekrany)
1. Tryb: `dedicated full` / `dedicated compact` / `saas` / `staging` (bez zmian).
2. **Dyski → dwie pule**: `fast` (SSD/NVMe: system gości, Postgres, docker, śluza uploadu) + `bulk` (HDD: `orgs`), każda z własnym RAID; jeden nośnik = jedna pula (`fast`=`bulk`). Wykrywanie SSD/HDD z `lsblk -d -o ROTA`.
3. LAN + kolizje, SSH port (bez zmian). 4. WG: podsieci/porty (bez zmian) + **DNS tunelu** (zawsze; `*.barvea.internal`).
5. Internet / air-gap / FQDN (bez zmian) + **nazwy hostów instancji**: `app.<domena>`, `drive.<domena>`, `admin.<domena>` (domyślnie `barvea.internal`; FQDN publiczny opcjonalnie tylko dla app).
6. **Backup**: storagebox / custom-sftp / **skip** (→ `backup-enable.sh` później, bez reinstalacji); lokalne dumpy zawsze.
7. **Vault**: domyślnie komplet kluczy u operatora (plik 0600 + wydruk raz) / opcja „podział Shamira” (checkbox).
8. **Pierwszy admin**: e-mail (+ nazwa org) — hasło GENEROWANE, pokazane raz na końcu i w pliku handover; 2FA wymuszone przy pierwszym logowaniu.
9. **Moduły**: Drive (WG+Samba+enroll) on/off (K1: ZFS-store zawsze); AV (clamd) on/off; współedycja on/off; kolizje/zestawienia IFC on/off (sidecary ciężkie → RAM!). Z modułów wynika preset RAM/CPU gości.
10. Licencja: plik lub „potem w panelu”.
11. Podsumowanie → `bootstrap.conf` + szkic `HANDOVER-<instancja>.md` (co trzeba otworzyć, kto trzyma klucze).

### D3 — `bootstrap.sh` v2
- Pule `fast`/`bulk` (phase_host): zvole VM na fast, `orgs` na bulk, śluza uploadu (scsi1) na fast.
- Goście wg presetu z modułów: VM 102 RAM = 8 G + suma sufitów włączonych sidecarów (prod: 32 G).
- VM 100: + dnsmasq (`network/dnsmasq-wg-users.conf`, INPUT 53 w wg-users), + `20auto-upgrades`.
- LXC 201: + veto globalne (`storage/samba/barvea-veto.conf`), + ClamAV natywny z socketem TCP (gdy AV on), + `20auto-upgrades`, acl-sync z `ORG_SLUGS` pustym (org-provision później).
- VM 102: Caddy **bez** `trusted_proxies` Cloudflare (on-prem: `client_ip` = adres TCP; wariant z CF tylko gdy FQDN publiczny + CF), vhost `admin.<domena>` (internal-CA), mTLS jak prod, `docker-prune.timer` (jest), scratch sidecarów (jest).
- **Vault**: krok prowadzony — bootstrap zatrzymuje się na ekranie „ceremonia”: wykonuje `operator init` (format JSON) → zapisuje klucze do `/root/barvea-vault-keys.json` (0600) **albo** drukuje je raz (tryb split) → `unseal ×3` → `bootstrap-vault.sh` → root-ca na LXC 201; potem `zfs-load-org` AppRole. Operator potwierdza, że klucze zabrał poza serwer.
- Restic: gdy backup ≠ skip → instalacja jobów z `backup/` na gościach i hoście (klucz SSH do repo, hasło repo → creds), pierwszy run; `backup-enable.sh` = ten sam kod wołany później.
- `phase_verify`: + testy DNS tunelu, clamd, veto, admin host, 404 internal.

### D4 — `deploy-app.dedicated.sh` v2 + bundle
- Bundle (APP): obrazy app + wszystkie sidecary wg modułów + postgres:18 + redis; `docker-compose.dedicated.yml` = prod compose z profilami per moduł; `env.template` 1:1 z `.env.example`.
- Skrypt: generuje sekrety (NEXTAUTH, TOTP_ENCRYPTION_KEY, MTLS_PROXY_SECRET, tokeny sidecarów, COLLAB JWT para, DRIVE_ACL_SERVICE_TOKEN → także do LXC 201), wpisuje hosty/URL-e z kreatora, `ADMIN_HOST`, `CSP_MODE=enforce` od razu (świeża instancja, bez legacy), `AV_MODE=block` gdy AV on → `docker load` → compose up → health → `bootstrap-instance` (admin + org + force-2FA) → licencja → smoke (login, 2FA, admin host, upload+AV, Drive enroll gdy on).
- Wynik: `HANDOVER-<instancja>.md` uzupełniony (adresy, porty, hasło admina raz, lokalizacja kluczy Vault, backup, jak zrobić update = `deploy-app` z nowym bundlem).

### D5 — Test od zera na VM 999 (#19) + DR
- Migawka `czysty-bootstrap` → wizard → bootstrap → ceremonia → deploy-app → smoke. Każdy błąd = fix w repo, nie na maszynie.
- DR-drill: restore dumpu Postgres z pre-deploy + `zfs-load-org` po restarcie + unseal.
- Potem: `INSTALL-DEDYK.md` v2, `HANDOVER.template.md`, tag wersji instalatora.

### Air-gap (po D5, osobny etap)
`build-offline-assets.sh` → mirror apt + obrazy + template; test `net0 link_down` na VM 999.

## 2. Zależności od innych czatów (prośby wysłane 23.11)
- APP: `docker-compose.dedicated.yml` z sidecarami i profilami modułów; `env.template` zsynchronizowany z `.env.example`; `bootstrap-instance` z `--force-2fa` i wyjściem hasła tylko na stdout raz; potwierdzenie, że `CSP_MODE=enforce` od razu jest bezpieczne dla świeżej instancji.
- Drive: lista endpointów klienta dla dedyka (hosty `*.<domena>` zamiast `barvea.internal`) — czy klient obsługuje inną domenę wewnętrzną (dziś pin SPKI + nazwy w appsettings).
- Plugin: „własny serwer” w kliencie = `https://app.<domena>` z CA organizacji (import CA do Windows przy instalacji Drive?).

## 3. Decyzje Miko — PODJĘTE 2026-11-23 wieczorem
1. Domena wewnętrzna dedyka: **stała `barvea.internal`** (tak nazywa się system; klienci Drive/plugin = jedna konfiguracja).
2. Vault: **automatyczny `operator init` w bootstrapie, klucze + root token do pliku 0600** (`/root/barvea-vault-keys.json`), operator zabiera plik poza serwer i potwierdza; tryb „podział Shamira” nadal opcją w kreatorze.
3. Test na VM 999: **ta sama struktura (5 gości), małe maszyny** — tylko walidacja ścieżki.
4. Moduły: **wybierane w kreatorze** (Drive, AV, współedycja, kolizje/IFC, chmury punktów), przy każdym informacja „+X GB RAM / +Y CPU”, na dole **licznik rekomendowanego RAM/CPU total** (baza 8 G + sufity: pcp 12, ifc-clash 12, ifc-extractor 4, office 3, dwg 3, collab 1; AV +1 G na LXC 201) i ostrzeżenie, gdy host ma mniej.
5. SMB a 2FA per org: **udziały rozłączne per organizacja** — osobne konto Samby na parę (użytkownik, org), każde tylko w grupie swojej org; `sessions/start` dla org B wydaje poświadczenia B dopiero po kodzie dla B. Osobny strumień S1 (poniżej), wchodzi na prod przed pierwszym dedykiem.

## 4. Strumień S1 — konta Samby per (użytkownik, org) [prod + instalator]
- Infra: `smb-provisiond` — provision/deprovision z `orgId`: nazwa konta `u_<userKey>_<orgKey>` (limit 32 znaki Samby → skróty), uid z puli, grupa primary = `org-<orgId>`, żadnych innych grup; hasło per konto; `acl-sync` bez zmian (ACL po grupach org). Migracja istniejących: dla każdego usera × org z grupy → nowe konto, stare konto usunięte po przełączeniu klientów.
- APP: `sessions/start`/`/devices/me` zwracają `smb_config` dla org docelowej (login per org), provisioning woła smb-provisiond z orgId; kontrakt — dokument od APP.
- Drive: montuje udział org z poświadczeniami z sesji tej org (dziś już tak, tylko login będzie inny per org); przełączenie org = nowe poświadczenia.
- Drive (odp. 23.11): klient przeżyje zmianę loginu; 4 punkty: (1) Windows 1219 (jedna sesja SMB z jednym loginem na nazwę hosta) → klient 0.1.9 zamyka wszystkie połączenia do hosta przed mountem innym loginem (alternatywa infra: host per org `<slug>.drive.barvea.internal` → to samo IP w dnsmasq — zmienia UNC w modelach Revita; rekomendacja Drive+infra: wspólny host, 1219 w kliencie; decyzja Miko); (2) kontrakt APP: `smb` powiązane z `active_org` (`smb.org_slug`), klient montuje tylko gdy slug się zgadza; (3) migracja: nowe konta OBOK starych → APP przełącza smb_config → `should_reconnect: true` w heartbeat dla żywych sesji → stare konta per user kasować dopiero po 1–2 dniach; should_reconnect w praktyce (0.1.8): z ważnym zaufaniem = ciche pełne połączenie (tunel i B: znikają na kilka sekund), bez zaufania = komunikat „połącz ponownie” + kod; pliki Revita z B: tracą połączenie na moment → **migracja poza godzinami pracy**; (4) format loginu w kontrakcie: infra proponuje `u_<userKey>_<orgKey>` (bez domeny, ≤ 32 znaki).
- Kolejność: kontrakt APP → smb-provisiond (infra, test na VM 999) → APP → migracja kont na prod (stare zostają 1–2 dni, should_reconnect) → Drive 0.1.9 (1219 + smb.org_slug).
