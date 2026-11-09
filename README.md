# billing-solution-infra-ansible

Ansible playbooks that provision and manage the **MyRace / billing-solution** production infrastructure (Region A).

Control node: Jenkins (`172.17.105.16`, user `devopsadmin`). Targets are RHEL-family hosts reached over SSH port `65297` as `root`.

---

## Architecture overview

| Layer | Components | Purpose |
|-------|------------|---------|
| **Databases** | PostgreSQL 16 + Patroni + etcd + HAProxy/Keepalived | Two HA Postgres clusters with VIP failover |
| **Cache** | Redis/Valkey + Sentinel | HA cache with automatic failover |
| **Messaging** | Kafka KRaft (+ MirrorMaker 2) | Event streaming; optional cross-region replication |
| **Object storage** | MinIO | S3-compatible backups / archives |
| **Shared FS** | NFS server | Log storage for Loki / Grafana |
| **Registry** | Harbor | Private container registry (HTTPS) |
| **CI/CD** | Jenkins (optional playbook) | Build / deploy control plane |
| **K8s** | Inventory only | Cluster hosts listed for reference; not provisioned here |

```text
                    Apps / K8s workers
                            |
          +-----------------+-----------------+
          |                 |                 |
   VIP :5000/:5001    Redis :6379        Kafka :9092
   (HAProxy)          (Sentinel)         (KRaft brokers)
          |
   +------+------+
   |             |
 Cluster 1    Cluster 2
 (Patroni)    (Patroni)
   |             |
 shared etcd (3 members, incl. etcd-witness)
```

---

## Infrastructure components

### 1. PostgreSQL HA (two clusters)

| | Cluster 1 | Cluster 2 |
|---|---|---|
| **Primary** | `db-a1a` `172.17.106.2` | `db-a2a` `172.17.106.4` |
| **Standby** | `db-a1b` `172.17.106.3` | `db-a2b` `172.17.106.5` |
| **Patroni scope** | `myrace-pg-cluster-1` | `myrace-pg-cluster-2` |
| **VIP** | `172.17.106.200` | `172.17.106.201` |
| **App port** | VIP `:5000` → leader `:5432` | same |
| **Replica port** | VIP `:5001` | same |

Stack per cluster:

- **PostgreSQL 16** — data plane
- **Patroni** — leader election / failover
- **etcd** — DCS (shared 3-node cluster: both C1 DB nodes + `etcd-witness` `172.17.106.6`)
- **HAProxy + Keepalived** — stable VIP in front of the Patroni leader
- **pgBackRest** — backup
- **PgBouncer** — optional connection pooling (separate playbooks)

Supporting DB playbooks also create per-service roles, ops user, metrics exporter, and Prometheus exporters (`postgres_exporter`, node exporter, HAProxy metrics).

### 2. Redis Sentinel

| Host | Role | IP |
|------|------|-----|
| `redis-a1` | master + sentinel | `172.17.105.7` |
| `redis-a2` | replica + sentinel | `172.17.105.8` |
| `etcd-witness` | sentinel-only | `172.17.106.6` |

- Ports: Redis `6379`, Sentinel `26379`
- Quorum `2` (survives one node loss)
- On RHEL 10+, role may install **Valkey** where the Redis package is unavailable

### 3. Kafka KRaft

| Host | Role | IP |
|------|------|-----|
| `kafka-a1` | broker + controller (`node.id=1`) | `172.17.105.9` |
| `kafka-a2` | broker + controller (`node.id=2`) | `172.17.105.10` |
| `etcd-witness` | controller-only witness (`node.id=3`) | `172.17.106.6` |

- No ZooKeeper — KRaft mode
- Client port `9092`, controller port `9093`
- Defaults: `replication.factor=2`, `min.insync.replicas=1`
- **MirrorMaker 2** playbook (on `kafka-a1`) for cross-region replication (Region A ↔ B)

### 4. MinIO

| Host | IP | Ports |
|------|-----|-------|
| `minio-a1` | `172.17.106.7` | API `9000`, console `9001` |

S3-compatible object store for backups/archives; designed for optional site replication to Region B.

### 5. NFS server

| Host | IP | Export |
|------|-----|--------|
| `nfs-a1` | `172.17.106.8` | `/exports/logs` (Loki / app / audit logs) |

Clients typically K8s workers in `172.17.0.0/16`.

### 6. Harbor registry

| Host | IP | Port |
|------|-----|------|
| `harbor-a1` | `172.17.105.17` | HTTPS `443` (self-signed until domain exists) |

Harbor **2.14.x** via online installer + Docker Compose. Default admin user: `admin`.

### 7. Jenkins (optional)

Playbook/role present; inventory host is commented out (`172.17.105.16` is also the Ansible control node).

### 8. Kubernetes (reference only)

`k8s-master-1` / `k8s-worker-*` are listed in inventory for documentation and cross-playbook addressing. **This repo does not provision the K8s cluster.**

---

## Repository layout

```text
.
├── ansible.cfg                 # inventory, SSH key, defaults
├── etc-ansible-hosts.txt       # inventory (groups + IPs)
├── group_vars/
│   ├── <group>/vars.yml        # non-secret config (committed)
│   ├── <group>/vault.yml       # secrets (gitignored)
│   └── <group>/vault.yml.example
├── roles/                      # etcd, postgres, patroni, haproxy, …
├── scripts/                    # ops helpers + SQL Jinja templates
└── *.yml                       # playbooks
```

---

## Secrets (like Terraform `*.tfvars`)

Sensitive values live in **`group_vars/<group>/vault.yml`**, which is **gitignored**.

```bash
cp group_vars/db_all/vault.yml.example group_vars/db_all/vault.yml
# repeat for: db2_all, haproxy, harbor, redis_sentinel, minio
# then edit vault.yml with real passwords
```

Do **not** commit `vault.yml`, `.vault_pass`, or plaintext passwords in SQL/scripts.

---

## Prerequisites

On the control node (Jenkins):

```bash
# collections
ansible-galaxy collection install -r requirements.yml

# SSH key (one-time) — see comments in etc-ansible-hosts.txt
ansible all -m ping
```

---

## Common playbooks

| Playbook | What it does |
|----------|----------------|
| `postgres-managed.yml` | etcd + both PG clusters (Postgres, Patroni, pgBackRest, HAProxy) |
| `postgres-cluster2.yml` | Cluster 2 only |
| `postgres-service-db-roles.yml` | Per-service DB roles (from vault) |
| `postgres-ops-user.yml` | Ops login role |
| `postgres-monitoring.yml` | metrics_exporter + DB/HAProxy exporters |
| `redis-sentinel.yml` | Redis/Valkey + Sentinel |
| `kafka-kraft.yml` | Kafka KRaft cluster |
| `kafka-mirrormaker2.yml` | Cross-region MirrorMaker 2 |
| `minio.yml` | MinIO object storage |
| `nfs-server.yml` | NFS log exports |
| `harbor.yml` | Harbor registry |
| `jenkins.yml` | Jenkins (optional) |
| `admin-sudo-user.yml` | Admin sudo user bootstrap |

Examples:

```bash
ansible-playbook postgres-managed.yml
ansible-playbook redis-sentinel.yml
ansible-playbook kafka-kraft.yml
ansible-playbook minio.yml
ansible-playbook nfs-server.yml
ansible-playbook harbor.yml
```

---

## App connectivity cheat sheet

| Service | Endpoint |
|---------|----------|
| Postgres C1 (RW) | `172.17.106.200:5000` |
| Postgres C1 (RO) | `172.17.106.200:5001` |
| Postgres C2 (RW) | `172.17.106.201:5000` |
| Postgres C2 (RO) | `172.17.106.201:5001` |
| Redis | `redis-a1` / Sentinel discovery (`26379`) |
| Kafka | `kafka-a1:9092`, `kafka-a2:9092` |
| MinIO S3 | `minio-a1:9000` |
| Harbor | `https://172.17.105.17` |
| NFS logs | `nfs-a1:/exports/logs` |

---

## Notes

- Inventory IPs and groups are the source of truth: `etc-ansible-hosts.txt`.
- Some older comments in playbooks may still mention prior VPC addresses; prefer inventory + `group_vars`.
- Sibling DR tree (if present elsewhere) is not part of this repository’s default layout.
