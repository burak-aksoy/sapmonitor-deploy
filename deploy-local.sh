#!/usr/bin/env bash
# =============================================================================
# SAP Monitoring Platform — Local Docker Deployment Script
# Usage: ./deploy-local.sh
# =============================================================================
set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites..."
command -v docker  >/dev/null 2>&1 || error "Docker is not installed."
command -v python3 >/dev/null 2>&1 || error "python3 is required to generate secrets."
success "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# ---------------------------------------------------------------------------
# 2. Create .env if it doesn't exist
# ---------------------------------------------------------------------------
if [ ! -f .env ]; then
  info "Creating .env from .env.example..."
  cp .env.example .env

  # Generate Fernet encryption key
  FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null \
    || python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")

  # Generate JWT secret
  JWT_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")

  # Write generated secrets into .env
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|ENCRYPTION_KEY=change-me-generate-a-fernet-key|ENCRYPTION_KEY=${FERNET_KEY}|" .env
    sed -i '' "s|JWT_SECRET_KEY=change-me-generate-a-strong-random-key|JWT_SECRET_KEY=${JWT_SECRET}|" .env
  else
    sed -i "s|ENCRYPTION_KEY=change-me-generate-a-fernet-key|ENCRYPTION_KEY=${FERNET_KEY}|" .env
    sed -i "s|JWT_SECRET_KEY=change-me-generate-a-strong-random-key|JWT_SECRET_KEY=${JWT_SECRET}|" .env
  fi

  success ".env created with generated secrets."
  warn "SAP_BASE_URL is still set to a placeholder — SAP polling will be skipped until configured."
  warn "Set your OPENAI_API_KEY in .env to enable LLM analysis."
else
  info ".env already exists — skipping generation."
fi

# ---------------------------------------------------------------------------
# 3. Stop any running containers
# ---------------------------------------------------------------------------
info "Stopping any existing containers..."
docker compose down --remove-orphans 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Build images
# ---------------------------------------------------------------------------
info "Building Docker images (this may take a few minutes on first run)..."
docker compose build --parallel
success "Images built."

# ---------------------------------------------------------------------------
# 5. Start infrastructure (postgres + redis) first
# ---------------------------------------------------------------------------
info "Starting PostgreSQL and Redis..."
docker compose up -d postgres redis

info "Waiting for PostgreSQL to be ready..."
until docker compose exec -T postgres pg_isready -U sapmon -q 2>/dev/null; do
  sleep 1
done
success "PostgreSQL is ready."

info "Waiting for Redis to be ready..."
until docker compose exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; do
  sleep 1
done
success "Redis is ready."

# ---------------------------------------------------------------------------
# 6. Start application services
# ---------------------------------------------------------------------------
info "Starting API, worker, beat, and frontend..."
docker compose up -d api worker beat frontend

# ---------------------------------------------------------------------------
# 7. Wait for API to be healthy
# ---------------------------------------------------------------------------
info "Waiting for API to be ready..."
MAX_WAIT=60
COUNT=0
until curl -sf http://localhost:8000/health >/dev/null 2>&1; do
  sleep 2
  COUNT=$((COUNT + 2))
  if [ "$COUNT" -ge "$MAX_WAIT" ]; then
    error "API did not become ready within ${MAX_WAIT}s. Check logs: docker compose logs api"
  fi
done
success "API is ready at http://localhost:8000"

# ---------------------------------------------------------------------------
# 8. Create default admin user (idempotent)
# ---------------------------------------------------------------------------
info "Creating default admin user (admin@company.com / changeme)..."
docker compose exec -T api python3 - <<'PYEOF' 2>/dev/null || warn "Admin user may already exist."
import asyncio

async def main():
    from app.database import AsyncSessionLocal
    from app.models.user import User, UserRole
    from app.services.auth_service import hash_password, get_user_by_email

    async with AsyncSessionLocal() as db:
        existing = await get_user_by_email(db, "admin@company.com")
        if existing:
            print("Admin user already exists.")
            return
        u = User(
            email="admin@company.com",
            full_name="Administrator",
            hashed_password=hash_password("changeme"),
            role=UserRole.ADMIN,
            is_active=True,
        )
        db.add(u)
        await db.commit()
        print("Admin user created.")

asyncio.run(main())
PYEOF

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  SAP Monitoring Platform is running!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "  Dashboard:    ${CYAN}http://localhost:80${NC}"
echo -e "  API docs:     ${CYAN}http://localhost:8000/api/docs${NC}"
echo -e "  Health check: ${CYAN}http://localhost:8000/health${NC}"
echo ""
echo -e "  Login:        ${YELLOW}admin@company.com${NC} / ${YELLOW}changeme${NC}"
echo ""
echo -e "  Useful commands:"
echo -e "    docker compose logs -f api      # API logs"
echo -e "    docker compose logs -f worker   # Celery worker logs"
echo -e "    docker compose logs -f beat     # Scheduler logs"
echo -e "    docker compose down             # Stop everything"
echo ""
echo -e "  Next steps:"
echo -e "    1. Edit ${YELLOW}.env${NC} — set SAP_BASE_URL, SAP credentials, OPENAI_API_KEY"
echo -e "    2. Edit Teams notification webhooks in the Teams settings UI"
echo -e "    3. Restart after .env changes: ${YELLOW}docker compose restart${NC}"
echo ""
