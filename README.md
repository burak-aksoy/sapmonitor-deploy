# SAP Monitor

SAP S/4HANA monitoring and alerting platform. Polls your SAP system for background job failures and IDoc errors, analyzes them with an LLM (GPT-4o, Claude, Gemini, or local Ollama), and dispatches alerts to the right team via Microsoft Teams and email.

**Key features:**
- Alert deduplication — same failure won't spam your team
- LLM-driven team routing — no hardcoded rules, just describe each team in plain language
- Job watch list — only watched jobs produce alerts (noise filter)
- Multi-LLM support — OpenAI, Anthropic Claude, Google Gemini, Ollama
- Escalation — unacknowledged alerts are re-notified automatically
- External integration health monitoring

---

## Installation

- [macOS / Linux](#macos--linux)
- [Windows](#windows)
- [Kubernetes](#kubernetes)

---

## macOS / Linux

**Requirements:** [Docker Desktop 24+](https://www.docker.com/products/docker-desktop/)

```bash
# 1. Download
curl -O https://raw.githubusercontent.com/burak-aksoy/sapmonitor-deploy/main/deploy-local.sh

# 2. Run
bash deploy-local.sh

# 3. Open
open http://localhost
```

The script auto-generates secrets, pulls images, and starts all services.

---

## Windows

**Requirements:** [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/) with WSL 2 backend enabled.

### Step 1 — Download the files

Open **PowerShell** and run:

```powershell
curl -O https://raw.githubusercontent.com/burak-aksoy/sapmonitor-deploy/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/burak-aksoy/sapmonitor-deploy/main/.env.example
copy .env.example .env
```

### Step 2 — Generate secrets

**Encryption key:**
```powershell
docker run --rm python:3.12-slim python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

**JWT secret:**
```powershell
-join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Maximum 256) })
```

Open `.env` in a text editor (Notepad, VS Code, etc.) and paste the generated values into `ENCRYPTION_KEY=` and `JWT_SECRET_KEY=`.

### Step 3 — Create data directories

```powershell
mkdir data\postgres
mkdir data\redis
```

### Step 4 — Start

```powershell
docker compose pull
docker compose up -d
```

### Step 5 — Open

Navigate to `http://localhost` in your browser.

**Default login:** `admin@company.com` / `changeme`

> **Port conflict:** If port 80 is already in use (e.g. IIS), edit `docker-compose.yml` and change `"80:80"` to `"8080:80"` under the `frontend` service, then access via `http://localhost:8080`.

> **Auto-start on boot:** Docker Desktop → Settings → General → enable "Start Docker Desktop when you log in". The `restart: unless-stopped` policy on all services handles the rest.

### Windows troubleshooting

| Problem | Fix |
|---------|-----|
| WSL 2 error on startup | Docker Desktop → Settings → General → enable "Use the WSL 2 based engine" |
| Container won't start | `docker compose logs <service-name>` |
| Port 80 in use | Change frontend port to `8080:80` in `docker-compose.yml` |

---

## Kubernetes

**Requirements:** A running Kubernetes cluster with `kubectl` configured. [cert-manager](https://cert-manager.io) and an ingress controller (e.g. ingress-nginx) are recommended for TLS.

### Step 1 — Create namespace and secrets

```bash
kubectl create namespace sapmonitor

kubectl create secret generic sapmonitor-env \
  --namespace sapmonitor \
  --from-env-file=.env
```

### Step 2 — Deploy

Save the following as `sapmonitor.yaml` and apply it:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sapmonitor-config
  namespace: sapmonitor
data:
  DATABASE_URL: "postgresql+asyncpg://sapmon:sapmon@postgres:5432/sapmon"
  REDIS_URL: "redis://redis:6379/0"

---
# PostgreSQL
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: sapmonitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - name: POSTGRES_USER
              value: sapmon
            - name: POSTGRES_PASSWORD
              value: sapmon
            - name: POSTGRES_DB
              value: sapmon
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: pgdata
          persistentVolumeClaim:
            claimName: postgres-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: sapmonitor
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: sapmonitor
spec:
  selector:
    app: postgres
  ports:
    - port: 5432

---
# Redis
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: sapmonitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: sapmonitor
spec:
  selector:
    app: redis
  ports:
    - port: 6379

---
# API
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: sapmonitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: aksoybrk/sapmonitor:backend-latest
          envFrom:
            - secretRef:
                name: sapmonitor-env
          ports:
            - containerPort: 8000
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: sapmonitor
spec:
  selector:
    app: api
  ports:
    - port: 8000

---
# Celery Worker
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  namespace: sapmonitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: worker
  template:
    metadata:
      labels:
        app: worker
    spec:
      containers:
        - name: worker
          image: aksoybrk/sapmonitor:backend-latest
          command: ["celery", "-A", "app.workers.celery_app", "worker",
                    "--loglevel=info", "-Q", "polling,analysis,dispatch", "-c", "4"]
          envFrom:
            - secretRef:
                name: sapmonitor-env

---
# Celery Beat (scheduler) — always exactly 1 replica
apiVersion: apps/v1
kind: Deployment
metadata:
  name: beat
  namespace: sapmonitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: beat
  template:
    metadata:
      labels:
        app: beat
    spec:
      containers:
        - name: beat
          image: aksoybrk/sapmonitor:backend-latest
          command: ["celery", "-A", "app.workers.beat_schedule", "beat", "--loglevel=info"]
          envFrom:
            - secretRef:
                name: sapmonitor-env

---
# Frontend
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: sapmonitor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: frontend
          image: aksoybrk/sapmonitor:frontend-latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: sapmonitor
spec:
  selector:
    app: frontend
  ports:
    - port: 80

---
# Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sapmonitor
  namespace: sapmonitor
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: sapmonitor.yourdomain.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api
                port:
                  number: 8000
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
```

```bash
kubectl apply -f sapmonitor.yaml
```

### Step 3 — Check rollout

```bash
kubectl get pods -n sapmonitor
kubectl rollout status deployment/api -n sapmonitor
```

### Step 4 — Access

Update `sapmonitor.yourdomain.com` in the Ingress to your actual domain, or use port-forward for local testing:

```bash
kubectl port-forward svc/frontend 8080:80 -n sapmonitor
# Open http://localhost:8080
```

> **Important:** `beat` (Celery scheduler) must always run as exactly **1 replica**. Do not scale it — duplicate beat instances will double-fire every scheduled task.

---

## After installation

**Default login:** `admin@company.com` / `changeme`
Change the password immediately via **Settings → Users**.

| URL | Purpose |
|-----|---------|
| http://localhost | Web dashboard |
| http://localhost:8000/api/docs | API docs (Swagger UI) |
| http://localhost:8000/health | Health check |

### 1. Connect your SAP system

Edit `.env` and set your SAP credentials, then restart:

```bash
docker compose restart worker beat   # Docker
kubectl rollout restart deployment/worker deployment/beat -n sapmonitor  # Kubernetes
```

**OAuth 2.0 (SAP RISE / BTP):**
```env
SAP_BASE_URL=https://your-s4-tenant.s4hana.ondemand.com
SAP_AUTH_TYPE=oauth2
SAP_CLIENT_ID=your-client-id
SAP_CLIENT_SECRET=your-client-secret
SAP_TOKEN_URL=https://your-btp-tenant.authentication.eu10.hana.ondemand.com/oauth/token
```

**Basic auth (on-premise):**
```env
SAP_BASE_URL=https://your-sap-host:44300
SAP_AUTH_TYPE=basic
SAP_USERNAME=MON_API
SAP_PASSWORD=your-password
```

> SAP connection is optional — the platform starts without it and skips polling until configured.

### 2. Set your LLM provider

```env
# OpenAI (default)
LLM_PROVIDER=openai
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o

# Anthropic Claude
LLM_PROVIDER=claude
ANTHROPIC_API_KEY=sk-ant-...
CLAUDE_MODEL=claude-sonnet-4-6

# Google Gemini
LLM_PROVIDER=gemini
GOOGLE_API_KEY=AIza...
GEMINI_MODEL=gemini-1.5-pro

# Ollama (local, no API key)
LLM_PROVIDER=ollama
OLLAMA_BASE_URL=http://host.docker.internal:11434
OLLAMA_MODEL=llama3.1
```

### 3. Configure notifications

**Microsoft Teams:** Go to **Settings → Teams** in the web UI and paste your Incoming Webhook URL for each team. Webhooks are encrypted before storage.

**Email:** Set SMTP credentials in `.env`:
```env
SMTP_HOST=smtp.office365.com
SMTP_PORT=587
SMTP_USER=sapmonitoring@yourcompany.com
SMTP_PASSWORD=your-app-password
```
Then add recipient addresses per team in **Settings → Teams**.

---

## Configuration reference

All settings live in `.env`. Restart services after any change.

### Security keys

| Variable | How to generate |
|----------|----------------|
| `JWT_SECRET_KEY` | `openssl rand -hex 32` |
| `ENCRYPTION_KEY` | `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |

> Changing `ENCRYPTION_KEY` after Teams webhooks are saved will make them unreadable — re-enter webhooks if you rotate this key.

### Polling intervals

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL_JOBS_SECONDS` | `300` | Background job polling (5 min) |
| `POLL_INTERVAL_IDOCS_SECONDS` | `300` | IDoc error polling (5 min) |
| `POLL_INTERVAL_INTEGRATIONS_SECONDS` | `120` | External integration health checks (2 min) |

### Data retention

| Variable | Default | Description |
|----------|---------|-------------|
| `RETENTION_ALERTS_DAYS` | `90` | Resolved/suppressed alerts |
| `RETENTION_HEALTH_SNAPSHOTS_DAYS` | `30` | Integration health history |
| `RETENTION_BACKGROUND_JOBS_DAYS` | `30` | Background job rows |
| `RETENTION_IDOC_RECORDS_DAYS` | `30` | IDoc record rows |

---

## Team routing

Routing is driven entirely by the database — no code changes needed.

Each team has a **Routing Description** (Settings → Teams). This text is injected into the LLM prompt at analysis time. The LLM reads all team descriptions and picks the best match.

Default teams seeded on first start:

| Team key | Routes when... |
|----------|----------------|
| `basis` | System landscape, transports, RFC failures, performance. **Default fallback.** |
| `basis_security` | Authorization failures (SU53), PFCG, user lockouts |
| `abap_developer` | ABAP dumps (ST22), Z-program failures, BAdI errors |
| `fi_consultant` | FI IDocs, payment runs (F110), GL/AP/AR, period-close |
| `mm_consultant` | MM IDocs, MRP runs, goods movements, PO processing |
| `sd_consultant` | SD IDocs, billing, credit management, delivery processing |
| `pp_consultant` | Production planning jobs, production orders, MES integration |
| `wm_consultant` | Warehouse management IDocs, transfer orders |
| `middleware` | REST/SOAP endpoints, SAP PI/PO, BTP Integration Suite |

To add a team: **Settings → Teams → Add Team** — fill in the routing description and webhook URL. Takes effect immediately.

---

## Operations

```bash
# Logs (Docker)
docker compose logs -f api
docker compose logs -f worker
docker compose logs -f beat

# Logs (Kubernetes)
kubectl logs -f deployment/api -n sapmonitor
kubectl logs -f deployment/worker -n sapmonitor

# Restart after .env changes (Docker)
docker compose restart

# Stop (Docker)
docker compose down

# Database backup (Docker)
docker compose exec postgres pg_dump -U sapmon sapmon > backup_$(date +%Y%m%d).sql

# Database backup (Kubernetes)
kubectl exec -n sapmonitor deployment/postgres -- pg_dump -U sapmon sapmon > backup_$(date +%Y%m%d).sql
```

---

## SAP ABAP setup

The platform polls two custom CDS views that must be created once by an ABAP developer. Estimated effort: 1–2 days.

### Background Jobs View — `Z_MON_BACKGROUND_JOBS`

```abap
@AbapCatalog.sqlViewName: 'ZV_MON_JOBS'
@AbapCatalog.compiler.compareFilter: true
@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'SAP Monitoring: Background Jobs'
@OData.publish: true

define view Z_MON_BACKGROUND_JOBS
  as select from tbtco as job
  left outer join tbtcs as step on step.jobname = job.jobname
                                and step.jobcount = job.jobcount
{
  key job.jobname     as JobName,
  key job.jobcount    as JobCount,
      job.status      as Status,
      job.sdlstrtdt   as ScheduledStartDate,
      job.sdlstrttm   as ScheduledStartTime,
      job.strtdate    as ActualStartDate,
      job.strttime    as ActualStartTime,
      job.enddate     as ActualEndDate,
      job.endtime     as ActualEndTime,
      job.jobclass    as JobClass,
      job.authckman   as UserName,
      step.progname   as ProgramName,
      step.abapclass  as AbapClass,
      ''              as ErrorMessage
}
where job.status in ( 'A', 'Z' )
```

### IDoc Errors View — `Z_MON_IDOC_ERRORS`

```abap
@AbapCatalog.sqlViewName: 'ZV_MON_IDOC'
@AbapCatalog.compiler.compareFilter: true
@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: 'SAP Monitoring: IDoc Errors'
@OData.publish: true

define view Z_MON_IDOC_ERRORS
  as select from edidc as hdr
  inner join edids as status on status.docnum = hdr.docnum
{
  key hdr.docnum      as DocNum,
      hdr.direct      as Direct,
      hdr.idoctp      as IdocType,
      hdr.mestyp      as MesType,
      hdr.sndprt      as SndPrt,
      hdr.sndprn      as SndPrn,
      hdr.rcvprt      as RcvPrt,
      hdr.rcvprn      as RcvPrn,
      hdr.credat      as CreDate,
      hdr.cretim      as CreTime,
      hdr.upddat      as UpdateDate,
      hdr.updtim      as UpdateTime,
      status.status   as Status,
      status.statxt   as StatusText,
      hdr.docrel      as SegmentCount
}
where status.status in ( '51', '52', '56', '63', '64', '65' )
-- 51=Application error, 52=Dispatch ok, 56=IDoc with errors,
-- 63=Error passing to port, 64=XML conversion error, 65=ALE service error
```

Activate both views via `/IWFND/MAINT_SERVICE` → Add Service → search the view name → add to system alias `LOCAL`.

Create a dedicated technical user (e.g. `MON_API`) with read-only access to `TBTCO`, `TBTCS`, `EDIDC`, `EDIDS` and the OData service endpoints.

---

## How it works

```
SAP S/4HANA RISE
  └── OData v4 (OAuth 2.0 or Basic Auth)
      ├── Background job failures (SM37)
      └── IDoc errors (WE05)
           │
           ▼
     Celery (polls every 5 min)
           │
           ▼
     LLM analysis + team routing
           │
     ┌─────┴─────┐
     ▼           ▼
  MS Teams     Email
 Adaptive     (SMTP)
   Cards
```

---

## Docker images

| Image | Tag | Description |
|-------|-----|-------------|
| `aksoybrk/sapmonitor` | `backend-latest` | FastAPI + Celery worker + beat |
| `aksoybrk/sapmonitor` | `frontend-latest` | React SPA served by Nginx |

---

## License

MIT
