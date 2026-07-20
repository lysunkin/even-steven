# Even Steven — Implementation & Deployment Plan

Stack: **Go (chi + huma) + PostgreSQL** backend · **React + TypeScript** frontend · **AWS** deployment.

---

## 1. Architecture Overview

```
┌───────────────────┐        ┌───────────────────────┐        ┌──────────────┐
│  React SPA        │ HTTPS  │  ALB → ECS Fargate    │  TCP   │  RDS         │
│  (S3 + CloudFront)├───────►│  Go API (chi + huma)  ├───────►│  PostgreSQL  │
└───────────────────┘        │  containers (2+ AZ)   │        └──────────────┘
                             └───────────────────────┘
                                     │
                                     ▼
                            Secrets Manager / SSM
                            (DB creds, JWT secret)
```

- **Frontend**: static React/TS SPA built and served from S3 via CloudFront (CDN + HTTPS).
- **Backend**: stateless Go REST API in Docker containers on ECS Fargate, behind an Application Load Balancer. huma generates OpenAPI spec + request/response validation on top of chi routing.
- **Database**: RDS PostgreSQL (single instance for MVP, Multi-AZ later).
- **Auth**: JWT-based, issued by the API; refresh tokens stored httpOnly.
- **No payment processing** — balances only, per your earlier decision.

---

## 2. Database Schema (PostgreSQL)

```sql
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    avatar_url    TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    created_by  UUID NOT NULL REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
    group_id    UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role        TEXT NOT NULL DEFAULT 'member', -- 'owner' | 'member'
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE group_invites (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    token       TEXT UNIQUE NOT NULL,
    email       TEXT,               -- optional, for targeted invites
    expires_at  TIMESTAMPTZ NOT NULL,
    created_by  UUID NOT NULL REFERENCES users(id)
);

-- Append-only: no UPDATE/DELETE against this table (see §2 Business Rules).
-- Corrections are made by inserting a new offsetting expense that references the original.
CREATE TABLE expenses (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id            UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    description         TEXT NOT NULL,
    total_amount        NUMERIC(12,2) NOT NULL,
    -- currency intentionally omitted: USD only for now (see Open Decisions).
    -- Add back if/when multi-currency is needed; don't build it speculatively.
    split_type          TEXT NOT NULL, -- 'equal' | 'exact' | 'percentage' | 'shares'
    expense_date        DATE NOT NULL,
    created_by          UUID NOT NULL REFERENCES users(id),
    corrects_expense_id UUID REFERENCES expenses(id), -- set when this row offsets/corrects an earlier one
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- who fronted the money (supports multiple payers for one expense)
CREATE TABLE expense_payers (
    expense_id  UUID NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    user_id     UUID NOT NULL REFERENCES users(id),
    amount_paid NUMERIC(12,2) NOT NULL,
    PRIMARY KEY (expense_id, user_id)
);

-- each participant's owed share of the expense
CREATE TABLE expense_shares (
    expense_id   UUID NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id),
    share_amount NUMERIC(12,2) NOT NULL, -- computed owed amount
    PRIMARY KEY (expense_id, user_id)
);

-- manual settlements AND partial immediate contributions
-- (e.g. "4 people paid $3 each right away" is 4 settlement rows against the expense)
CREATE TABLE settlements (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    expense_id  UUID REFERENCES expenses(id) ON DELETE SET NULL, -- nullable: general settle-up isn't tied to one expense
    from_user   UUID NOT NULL REFERENCES users(id), -- debtor, the one paying back
    to_user     UUID NOT NULL REFERENCES users(id), -- creditor, the one receiving
    amount      NUMERIC(12,2) NOT NULL,
    note        TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Rounding remainder from uneven splits does NOT get assigned to any member.
-- It accrues to a per-group "pool" that the group's payer/owner can later draw
-- on to cover future costs (per your rounding-policy decision).
CREATE TABLE pool_transactions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    expense_id  UUID REFERENCES expenses(id) ON DELETE SET NULL, -- source expense, for rounding credits
    type        TEXT NOT NULL, -- 'rounding_credit' | 'withdrawal'
    amount      NUMERIC(12,2) NOT NULL, -- always positive; type determines sign in balance calc
    note        TEXT,
    created_by  UUID NOT NULL REFERENCES users(id), -- for withdrawals, must be group owner
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_expenses_group ON expenses(group_id);
CREATE INDEX idx_settlements_group ON settlements(group_id);
CREATE INDEX idx_shares_user ON expense_shares(user_id);
CREATE INDEX idx_pool_group ON pool_transactions(group_id);
```

**Pool balance** for a group = `SUM(rounding_credit) - SUM(withdrawal)`. Enforce in the service layer that only a `group_members.role = 'owner'` can insert a `withdrawal` row, and that a withdrawal can't exceed the current pool balance.

**Balance derivation** (no stored "balance" table — always computed, to avoid drift):
```
net(A owes B) = SUM(expense_shares for A on expenses where B is a payer, prorated)
              - SUM(settlements from A to B)
              + SUM(settlements from B to A)   -- symmetric netting
```
Compute this per group as a pairwise matrix, then run a **debt-simplification pass** (greedy: sort net debtors/creditors, match largest debtor to largest creditor repeatedly) to minimize the number of suggested payments.

---

## 3. Backend (Go + chi + huma)

### 3.1 Project layout
```
even-steven-api/
├── cmd/
│   └── api/main.go              # entrypoint: config, DB pool, router, server start
├── internal/
│   ├── config/                  # env var loading (viper or plain os.Getenv)
│   ├── db/                      # sqlc-generated or pgx queries, migrations
│   │   └── migrations/          # goose or golang-migrate .sql files
│   ├── auth/                    # JWT issuance/validation, password hashing (bcrypt/argon2)
│   ├── middleware/               # auth middleware, request logging, CORS, recover
│   ├── users/                   # handler, service, repository per domain
│   ├── groups/
│   ├── expenses/
│   ├── settlements/
│   ├── balances/                # balance computation + debt simplification logic
│   └── httpapi/                 # huma API registration, route wiring
├── go.mod
├── Dockerfile
└── docker-compose.yml           # local Postgres + API
```

### 3.2 Key libraries
- **chi** — routing
- **huma** — OpenAPI-driven request/response validation, auto-generates `/docs` and `/openapi.json`
- **pgx** + **sqlc** (recommended) — typed SQL without a heavy ORM; keeps balance-calculation queries explicit and auditable
- **golang-migrate** or **goose** — schema migrations
- **golang-jwt/jwt** — JWT auth
- **testcontainers-go** — integration tests against a real Postgres container

### 3.3 REST API surface (v1)

| Method | Path | Description |
|---|---|---|
| POST | `/v1/auth/signup` | Create account |
| POST | `/v1/auth/login` | Returns access + refresh token |
| POST | `/v1/auth/refresh` | Rotate access token |
| GET  | `/v1/me` | Current user profile |
| POST | `/v1/groups` | Create group |
| GET  | `/v1/groups` | List my groups |
| GET  | `/v1/groups/{id}` | Group detail + members |
| POST | `/v1/groups/{id}/invites` | Create invite link |
| POST | `/v1/invites/{token}/accept` | Join group via invite |
| POST | `/v1/groups/{id}/expenses` | Add expense (payer(s), split type, participants) |
| GET  | `/v1/groups/{id}/expenses` | List expenses (paginated) |
| GET  | `/v1/expenses/{id}` | Expense detail |
| POST | `/v1/expenses/{id}/correct` | Append an offsetting expense that corrects this one (no PATCH/DELETE — append-only ledger) |
| POST | `/v1/groups/{id}/settlements` | Record a manual payment (full or partial) |
| GET  | `/v1/groups/{id}/balances` | Pairwise + simplified balances for the group |
| GET  | `/v1/users/{id}/balances` | Net balance with this user across all shared groups |
| GET  | `/v1/groups/{id}/pool` | Pool balance + transaction history (rounding credits, withdrawals) |
| POST | `/v1/groups/{id}/pool/withdraw` | Owner-only: draw from the pool to cover a cost |
| GET  | `/v1/groups/{id}/activity` | Chronological feed |

huma lets you define each of these as a typed Go struct for input/output, so the OpenAPI docs and client-side TS types (via `openapi-typescript`) stay in sync automatically — worth setting up early.

### 3.4 Example: split calculation entry point
```go
type CreateExpenseInput struct {
    GroupID     string
    Description string
    TotalAmount decimal.Decimal
    SplitType   string // equal | exact | percentage | shares
    Payers      []PayerInput   // user_id + amount_paid
    Participants []ParticipantInput // user_id + (share/percentage/exact amount, depending on SplitType)
}
```
Validate that `sum(Payers.amount_paid) == TotalAmount` and that participant shares reconcile to `TotalAmount` (handle rounding remainder by assigning the odd cent to the first participant, a common Splitwise convention).

---

## 4. Frontend (React + TypeScript)

### 4.1 Project layout
```
even-steven-web/
├── src/
│   ├── api/              # generated client from OpenAPI spec + hand-written fetch wrapper
│   ├── auth/              # auth context, token storage, protected routes
│   ├── features/
│   │   ├── groups/
│   │   ├── expenses/
│   │   ├── settlements/
│   │   └── balances/
│   ├── components/        # shared UI (Button, Modal, Avatar, etc.)
│   ├── pages/              # route-level components
│   ├── hooks/
│   ├── lib/                # formatting (currency), validation
│   └── App.tsx
├── vite.config.ts
├── package.json
└── Dockerfile              # multi-stage build → static files
```

### 4.2 Stack choices
- **Vite** for build tooling (fast, simple, works well for SPA + S3 hosting)
- **React Router** for routing
- **TanStack Query** for server state (caching, refetch on mutation — fits a balances/expenses app well)
- **React Hook Form + Zod** for expense/split forms with validation
- **Tailwind CSS** for styling — mobile-first utility classes make the responsive requirement below straightforward
- **openapi-typescript** or **orval** to generate typed API client + hooks straight from the Go backend's huma-generated OpenAPI spec — keeps frontend/backend in sync without manual typing

### 4.3 Responsive design (desktop + mobile browser)
One React codebase, no separate mobile app — responsive layout via Tailwind breakpoints (`sm`/`md`/`lg`).
- **Mobile-first**: design each screen for a narrow viewport first, then layer on desktop enhancements (e.g. a two-column layout on desktop that stacks to one column on mobile).
- **Navigation**: bottom tab bar or hamburger menu on mobile; persistent sidebar on desktop (`≥md`).
- **Tables → cards**: the balances/activity views likely render as tables on desktop but should collapse to a stacked card layout on mobile — build this as a single component that switches layout via CSS, not two separate components, to avoid logic duplication.
- **Forms**: the "add expense" split-entry form (payer/participant pickers, amount inputs) needs extra care on small screens — use full-screen modals/sheets on mobile vs. inline modals on desktop.
- **Touch targets**: minimum 44×44px tappable areas on mobile for buttons like "settle up" and split-method toggles.
- **Testing**: add mobile viewport presets (e.g. 375×667) alongside desktop (1280×800) to the Playwright e2e suite so both are covered in CI, not just checked manually.
- No native app in this plan (no React Native/Capacitor) — if a true native/PWA-installable experience is wanted later, that's a separate phase (e.g. add a PWA manifest + service worker for "add to home screen" support, which is a relatively small addition on top of this SPA).

### 4.4 Key screens
1. Login / Signup
2. Groups list (with net balance summary per group)
3. Group detail: activity feed + "Add expense" + "Settle up" buttons
4. Add expense form: description, amount, payer(s), split method (equal/exact/percentage/shares), participant picker
5. Balances view: simplified "who pays whom" list per group, plus a cross-group "your balance with [friend]" view
6. Settle up modal: record a payment against an existing debt (supports partial amounts, matching your $3-of-$11.25 example)

---

## 5. AWS Deployment

### 5.1 Environments
Two environments to start: `staging` and `prod`, same topology, separate AWS accounts or namespaced resources.

### 5.2 Core resources
| Component | AWS Service |
|---|---|
| Frontend hosting | S3 (static site) + CloudFront (CDN, HTTPS via ACM cert) |
| Backend compute | ECS Fargate service (2 tasks min, autoscale on CPU/requests) |
| Load balancing | Application Load Balancer, HTTPS listener |
| Database | RDS PostgreSQL (db.t4g.micro for staging, db.t4g.small+ Multi-AZ for prod) |
| Secrets | AWS Secrets Manager (DB creds, JWT signing key) |
| Container registry | ECR |
| DNS | Route 53 |
| CI/CD | GitHub Actions → ECR push → ECS deploy; S3 sync + CloudFront invalidation for frontend |
| Observability | CloudWatch Logs (ECS task logs), CloudWatch Alarms on 5xx rate / CPU / DB connections |
| IaC | Terraform (recommended) or AWS CDK — define all of the above as code from day one |

### 5.3 Suggested repo/infra structure
```
even-steven-infra/
├── modules/
│   ├── network/        # VPC, subnets, security groups
│   ├── database/        # RDS instance, subnet group, parameter group
│   ├── ecs-service/      # Fargate task def, service, ALB target group
│   └── frontend/         # S3 bucket, CloudFront distribution, ACM cert
└── envs/
    ├── staging/main.tf
    └── prod/main.tf
```

### 5.4 CI/CD pipeline (GitHub Actions, high level)
1. **On PR**: lint + unit tests (Go `go test ./...`, frontend `vitest`/`jest`), build Docker image, run migrations against ephemeral test DB (testcontainers).
2. **On merge to `main`**: build + push image to ECR tagged with commit SHA → deploy to staging (ECS `update-service` with new task def) → run smoke tests.
3. **Manual approval gate** → promote same image tag to prod.
4. **Frontend**: build with `vite build`, sync `dist/` to S3, invalidate CloudFront cache.
5. **DB migrations**: run as a separate one-off ECS task (or GitHub Actions step with a bastion/SSM tunnel) before the new API version deploys, so schema and code changes are decoupled and reversible.

### 5.5 Local development
`docker-compose.yml` at the repo root (or a top-level `even-steven` monorepo) spinning up:
- `postgres:16` with a seed script
- Go API container (hot reload via `air`)
- Vite dev server for frontend, proxying `/v1/*` to the local API

---

## 6. Suggested Build Order (Milestones)

1. **Foundations**: repo scaffolding (Go module, Vite app, docker-compose), DB migrations for `users`, `groups`, `group_members`, basic auth (signup/login/JWT).
2. **Groups & invites**: create group, invite link, join flow.
3. **Expenses core**: add expense with equal split only, list expenses, compute simple balances (this alone covers your $45/4-people example).
4. **Flexible splitting**: exact/percentage/shares split types, multiple payers per expense.
5. **Settlements**: record manual/partial payments, recompute balances, debt-simplification algorithm.
6. **Cross-group balances**: net balance per friend across all groups.
7. **Polish**: activity feed, pagination, basic notifications (email on new expense — can wait for v2).
8. **AWS deployment**: Terraform for staging, CI/CD pipeline, then prod.

---

## 7. Testing Strategy
- **Backend**: table-driven unit tests for split/balance-calculation logic (this is the part most worth testing exhaustively — rounding edge cases, partial settlements, multi-payer expenses); integration tests with testcontainers-go against real Postgres for repository/handler layers.
- **Frontend**: component tests (Vitest + React Testing Library) for the expense form and balance display; a handful of Playwright e2e tests for the critical path (signup → create group → add expense → settle up).
- **Contract**: since huma generates the OpenAPI spec, add a CI check that the generated TS client is up to date with the backend spec (fails the build if someone changes an endpoint without regenerating).

---

## 8. Confirmed Decisions
- **Rounding**: leftover cents from uneven splits are never assigned to a member. They accrue to a per-group `pool_transactions` ledger; the group owner can withdraw pool funds later to cover costs. No hidden "who eats the odd cent" logic on individual shares.
- **Append-only ledger**: expenses are never edited or deleted. Mistakes are corrected by inserting a new expense via `POST /v1/expenses/{id}/correct`, linked back via `corrects_expense_id`, so the full history stays auditable. Balance calculations sum all expenses/corrections chronologically — a correction is just another entry, not a mutation.
- **Currency**: USD only for now. No `currency` column on `expenses`; all amounts are implicitly USD. If multi-currency is needed later, add the column and a conversion strategy then rather than building for it speculatively now.
