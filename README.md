# Oracle-OnPrem_DB

Unattended installer for **Oracle AI Database 26ai Free + ORDS 26 + APEX 26.2** on a single local Ubuntu machine
(22.04 – 26.04, x86_64 or aarch64), plus a network patch so APEX can call a local **vLLM**.

Tested end to end on Ubuntu 26.04: DB 23.26.3 (26ai), APEX 26.2.0, ORDS 26.3, vLLM 0.33 (CPU) with Qwen3.5-0.8B.

```bash
chmod +x install-oracle-26ai.sh setup-vllm-cpu.sh
sudo ./install-oracle-26ai.sh                   # install (safe to re-run, resumes after a failure)
sudo ./install-oracle-26ai.sh --status          # show status (incl. network ACLs)
sudo ./install-oracle-26ai.sh --patch-network   # re-apply vLLM ACL + test
sudo ./install-oracle-26ai.sh --diagnose        # print what is needed to debug a failure
sudo ./install-oracle-26ai.sh --uninstall       # remove everything (asks first; --yes to skip)

sudo ./setup-vllm-cpu.sh                        # optional: small CPU-only vLLM on 127.0.0.1:8000
```

## Requirements

| | Minimum | Notes |
|---|---|---|
| Disk | **25 GB free** (15 GB if the DB image is already pulled) | DB image ~9 GB, DB files + APEX ~10 GB. Running out during APEX gives `SP2-0308: cannot close spool file`. The vLLM CPU image adds ~8 GB. |
| RAM | 4 GB for DB + ORDS; **12 GB+ with vLLM** | With 7 GB, vLLM gets swapped out and the first APEX call can time out (`ORA-29273`). |
| CPU | x86_64 or aarch64 | vLLM CPU needs AVX2 (AVX512 is faster). |

On Ubuntu's default LVM layout the root volume often doesn't use the whole disk. Check with `sudo vgs` (look at `VFree`)
and grow it with `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`.

Only one copy of the installer runs at a time (lock file). If the APEX step fails, the half-finished APEX is removed
automatically on the next run, and the APEX logs are kept in `/var/log/oracle-26ai/apex/`.

## Local vLLM from APEX

The database container uses **host networking** by default, so `http://localhost:8000` inside the
database is your machine's vLLM. The install grants the APEX schema `connect`/`http` (port 8000) and
`resolve` on `localhost` and `127.0.0.1`, which avoids `ORA-24247: network access denied by access control list`.
It then calls `http://localhost:8000/v1/models` through `APEX_WEB_SERVICE` to check that it works.

In APEX: *Workspace Utilities → Generative AI → Create*, provider **OpenAI**, URL `http://localhost:8000/v1`.

If vLLM isn't running during install, start it later and run `sudo ./install-oracle-26ai.sh --patch-network`.

| Component | How it runs |
|---|---|
| Oracle AI Database 26ai Free | Official container `container-registry.oracle.com/database/free:latest` (Docker, `--restart unless-stopped`), data in `/opt/oracle/oradata` |
| APEX 26.2 | Installed into PDB `FREEPDB1`; static files in `/opt/oracle/apex/images` |
| ORDS 26 | Native Java service `ords.service` (systemd), config in `/etc/ords/config`, port 8080 |

Generated passwords are saved in `/etc/oracle-26ai/credentials.env` (root only). The install log is `/var/log/oracle-26ai-install.log`.

Common overrides (environment variables, or put them in `/etc/oracle-26ai/install.conf`):

| Variable | Default | Purpose |
|---|---|---|
| `ORACLE_PWD` | generated | SYS/SYSTEM/PDBADMIN password |
| `APEX_ADMIN_PWD` | generated | APEX `INTERNAL`/`ADMIN` password |
| `ORDS_HTTP_PORT` | `8080` | ORDS / APEX port |
| `EXPOSE_DB_PORT` | `no` | `yes` opens 1521 in ufw (in bridge mode, also binds it to all interfaces) |
| `DB_NETWORK` | `host` | `bridge` = isolated container; vLLM then must listen on `0.0.0.0` and is reached as `host.docker.internal` |
| `VLLM_PORT` | `8000` | vLLM port granted in the ACL |
| `VLLM_HOSTS` | `localhost 127.0.0.1` | Hosts granted in the ACL |
| `VLLM_API_KEY` | empty | Bearer key for the test call, if vLLM uses `--api-key` |
| `ACL_EXTRA_SCHEMAS` | empty | Workspace schemas that call `UTL_HTTP`/`APEX_WEB_SERVICE` themselves |
| `APEX_URL` | `.../apex_26.2.zip` | Pin a specific APEX zip |
| `ORDS_URL` | `.../ords-latest.zip` | Pin a specific ORDS zip |
| `STRICT_VERSIONS` | `no` | `yes` stops the install if the APEX/ORDS versions don't match |
