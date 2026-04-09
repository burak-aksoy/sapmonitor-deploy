# SAP Monitor <!-- retry -->

SAP S/4HANA monitoring and alerting platform. Polls your SAP system for background job failures and IDoc errors, analyzes them with an LLM (GPT-4o, Claude, Gemini, or local Ollama), and dispatches alerts to the right team via Microsoft Teams and email.

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

**Key features:**
- Alert deduplication — same failure won't spam your team
- LLM-driven team routing — no hardcoded rules, just describe each team in plain language
- Job watch list — only watched jobs produce alerts (noise filter)
- Multi-LLM support — OpenAI, Anthropic Claude, Google Gemini, Ollama
- Escalation — unacknowledged alerts are re-notified automatically
- External integration health monitoring

---

## Quick start

### Prerequisites

- Docker Desktop 24+ (includes Docker Compose v2)
- Python 3 (for secret generation)

### Option A — Automated (recommended)

```bash
curl -O https://raw.githubusercontent.com/burak-aksoy/sapmonitor-deploy/main/deploy-local.sh
bash deploy-local.sh
```

The script creates `.env` with auto-generated secrets, pulls images, and starts all services.

### Option B — Manual

```bash
# 1. Download the required files
curl -O https://raw.githubusercontent.com/burak-aksoy/sapmonitor-deploy/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/burak-aksoy/sapmonitor-deploy/main/.env.example

# 2. Create your .env
cp .env.example .env

# 3. Generate required secrets
python3 -c "from cryptography.fernet import Fernet; print('ENCRYPTION_KEY=' + Fernet.generate_key().decode())"
python3 -c "import secrets; print('JWT_SECRET_KEY=' + secrets.token_hex(32))"
# Paste the output values into .env

# 4. Pull and start
docker compose pull
docker compose up -d
```

After startup:

| URL | Purpose |
|-----|---------|
| http://localhost | Web dashboard |
| http://localhost:8000/api/docs | Swagger UI |
| http://localhost:8000/health | Health check |

**Default login:** `admin@company.com` / `changeme`
Change the password via **Settings → Users** after first login.

---

## Configuration

All configuration lives in `.env`. Copy `.env.example` → `.env` and fill in values.
Restart after changes: `docker compose restart`

### SAP Connection

| Variable | Description |
|----------|-------------|
| `SAP_BASE_URL` | Your S/4HANA tenant URL |
| `SAP_AUTH_TYPE` | `oauth2` (RISE) or `basic` (on-premise) |
| `SAP_CLIENT_ID` | OAuth 2.0 client ID |
| `SAP_CLIENT_SECRET` | OAuth 2.0 client secret |
| `SAP_TOKEN_URL` | BTP token endpoint |
| `SAP_USERNAME` / `SAP_PASSWORD` | Basic auth only |

SAP connection is optional — the platform starts without it and skips polling until configured.

### LLM Provider

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_PROVIDER` | `openai` | `openai` \| `claude` \| `gemini` \| `ollama` |
| `OPENAI_API_KEY` | — | Required if using OpenAI |
| `ANTHROPIC_API_KEY` | — | Required if using Claude |
| `GOOGLE_API_KEY` | — | Required if using Gemini |
| `OLLAMA_BASE_URL` | `http://localhost:11434` | Required if using Ollama |
| `LLM_FALLBACK_PROVIDER` | — | Optional secondary provider if primary fails |

### Email (SMTP)

| Variable | Example |
|----------|---------|
| `SMTP_HOST` | `smtp.office365.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USER` | `sapmonitoring@yourcompany.com` |
| `SMTP_PASSWORD` | your app password |

Email recipients are configured per team in **Settings → Teams**.

### Security

| Variable | How to generate |
|----------|----------------|
| `JWT_SECRET_KEY` | `openssl rand -hex 32` |
| `ENCRYPTION_KEY` | `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |

> **Important:** Changing `ENCRYPTION_KEY` after Teams webhooks have been saved will make those webhooks unreadable — they must be re-entered.

### Polling intervals

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL_JOBS_SECONDS` | `300` | Background job polling (5 min) |
| `POLL_INTERVAL_IDOCS_SECONDS` | `300` | IDoc error polling (5 min) |
| `POLL_INTERVAL_INTEGRATIONS_SECONDS` | `120` | External integration health checks (2 min) |

### Data retention

| Variable | Default | Description |
|----------|---------|-------------|
| `RETENTION_ALERTS_DAYS` | `90` | Days to keep resolved/suppressed alerts |
| `RETENTION_HEALTH_SNAPSHOTS_DAYS` | `30` | Integration health history |
| `RETENTION_BACKGROUND_JOBS_DAYS` | `30` | Background job rows |
| `RETENTION_IDOC_RECORDS_DAYS` | `30` | IDoc record rows |

---

## SAP ABAP Setup

The platform requires two custom CDS views in your SAP system. This is a one-time setup by an ABAP developer.

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
```

Activate both views via `/IWFND/MAINT_SERVICE` → Add Service → search the view name → add to system alias `LOCAL`.

Create a dedicated technical user (e.g. `MON_API`) with read-only access to `TBTCO`, `TBTCS`, `EDIDC`, `EDIDS` and the OData service endpoints.

---

## Team routing

Routing is driven entirely by the database — no code changes needed.

Each team has a **Routing Description** (Settings → Teams). This text is injected into the LLM prompt at analysis time. The LLM reads all team descriptions and picks the best match.

Default teams seeded on first start: `basis`, `basis_security`, `abap_developer`, `fi_consultant`, `mm_consultant`, `sd_consultant`, `pp_consultant`, `wm_consultant`, `middleware`.

To add a team: **Settings → Teams → Add Team** — fill in the routing description and webhook URL. Active immediately.

---

## Operations

```bash
# Logs
docker compose logs -f api
docker compose logs -f worker
docker compose logs -f beat

# Restart after .env changes
docker compose restart

# Stop
docker compose down

# Database backup
docker compose exec postgres pg_dump -U sapmon sapmon > backup_$(date +%Y%m%d).sql
```

---

## Docker images

| Image | Tag | Description |
|-------|-----|-------------|
| `aksoybrk/sapmonitor` | `backend-latest` | FastAPI + Celery worker + beat |
| `aksoybrk/sapmonitor` | `frontend-latest` | React SPA served by Nginx |

Images are automatically updated on every release.

---

## License

MIT
