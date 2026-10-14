# VM 102 (barvea-app) — unity systemd

| Unit | Rola |
|---|---|
| `docker-prune.service` + `.timer` | niedziela 04:30: `docker builder prune --filter until=168h` + `image prune`. Build cache rośnie ~37 GB na deploy; bez tego root (75 G) zapełnia się po 2 deployach. |

Instalacja (bootstrap `svc_app` robi to samo):
```bash
# barvea-app
sudo cp ~/barvea/vm102/systemd/docker-prune.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now docker-prune.timer
systemctl list-timers docker-prune.timer --no-pager
```
Ręczne odpalenie / test: `sudo systemctl start docker-prune.service && df -h /`.

Katalog nazywa się `vm102/`, nie `app/` — `app/` w tym repo to gitignorowany klon
repo aplikacji.
