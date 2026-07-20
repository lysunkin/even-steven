# Even Steven

A group-expense ledger app. Friends log shared expenses (e.g. group food orders), split them evenly or unevenly, and see a running "who owes whom" balance per group and across groups. No real payments are moved — settlements (including partial ones) are recorded manually.

> Full design rationale, schema, and deployment details: see [`even-steven-implementation-plan.md`](./even-steven-implementation-plan.md).

## Subprojects (monorepo)

| Path | Description |
|---|---|
| `even-steven-api/` | Go backend — REST API (chi + huma), business logic, DB access |
| `even-steven-web/` | React + TypeScript frontend — responsive SPA (desktop + mobile browser) |
| `even-steven-infra/` | Terraform IaC for AWS deployment (staging + prod) |

## Repository Layout

```
even-steven/
├── even-steven-api/
│   ├── cmd/api/main.go              # entrypoint
│   ├── internal/
│   │   ├── config/                  # env config
│   │   ├── db/migrations/           # goose/golang-migrate SQL migrations
│   │   ├── auth/                    # JWT issuance/validation
│   │   ├── middleware/              # auth, CORS, logging, recover
│   │   ├── users/
│   │   ├── groups/
│   │   ├── expenses/                # append-only expense logic
│   │   ├── settlements/
│   │   ├── balances/                # balance derivation + debt simplification
│   │   ├── pool/                    # rounding-remainder pool ledger
│   │   └── httpapi/                 # huma route registration
│   ├── go.mod
│   ├── Dockerfile
│   └── docker-compose.yml           # local Postgres + API
│
├── even-steven-web/
│   ├── src/
│   │   ├── api/                     # generated client from OpenAPI spec
│   │   ├── auth/                    # auth context, token storage
│   │   ├── features/
│   │   │   ├── groups/
│   │   │   ├── expenses/
│   │   │   ├── settlements/
│   │   │   └── balances/
│   │   ├── components/              # shared UI (responsive: mobile-first Tailwind)
│   │   ├── pages/
│   │   ├── hooks/
│   │   └── lib/                     # formatting, validation
│   ├── vite.config.ts
│   ├── package.json
│   └── Dockerfile
│
├── even-steven-infra/
│   ├── modules/
│   │   ├── network/                 # VPC, subnets, security groups
│   │   ├── database/                # RDS Postgres
│   │   ├── ecs-service/             # Fargate task/service, ALB target group
│   │   └── frontend/                # S3 bucket, CloudFront, ACM cert
│   └── envs/
│       ├── staging/main.tf
│       └── prod/main.tf
│
├── even-steven-implementation-plan.md
└── README.md
```

## Technology Stack

**Backend**
- Go
- chi (routing) + huma (OpenAPI-driven validation, auto-generated docs/spec)
- PostgreSQL (via pgx / sqlc), golang-migrate or goose for migrations
- JWT auth (golang-jwt)
- testcontainers-go for integration tests

**Frontend**
- Node.js / TypeScript / React
- Vite (build tooling)
- React Router, TanStack Query (server state)
- React Hook Form + Zod (forms/validation)
- Tailwind CSS — mobile-first, responsive across desktop and mobile browsers (single codebase, no native app)
- openapi-typescript / orval — typed client generated from the backend's OpenAPI spec

**Infrastructure — AWS**
- Frontend: S3 + CloudFront (static SPA hosting, HTTPS via ACM)
- Backend: ECS Fargate behind an Application Load Balancer
- Database: RDS PostgreSQL
- Secrets: AWS Secrets Manager
- Registry: ECR
- DNS: Route 53
- IaC: Terraform
- CI/CD: GitHub Actions (test → build → push to ECR → deploy to ECS; S3 sync + CloudFront invalidation for frontend)

## Key Design Decisions

- **Ledger, not payments** — the app only tracks balances; no Stripe/PayPal/Venmo integration.
- **Multi-group, invite-based** — users can belong to many groups; balances are viewable per group and net across groups with a given friend.
- **Append-only expenses** — expenses are never edited or deleted. Corrections are made by inserting a new offsetting expense linked to the original (`corrects_expense_id`), preserving full history.
- **Rounding pool** — leftover cents from uneven splits are never assigned to an individual member. They accrue to a per-group pool that the group owner can withdraw later to cover costs.
- **USD only** — no currency field/conversion logic for now; add it later if needed rather than building it speculatively.
- **Responsive web only** — one React codebase covers desktop and mobile browsers via responsive layout; no native mobile app (a PWA manifest could be added later for installability).

## Local Development

```bash
# from repo root
docker-compose up          # Postgres + Go API (hot reload via air)
cd even-steven-web && npm run dev   # Vite dev server, proxies /v1/* to local API
```

## Suggested Build Order

1. Repo scaffolding, auth (signup/login/JWT)
2. Groups & invites
3. Expenses core (equal split only) + basic balances
4. Flexible splitting (exact/percentage/shares, multi-payer expenses)
5. Settlements (including partial) + debt-simplification algorithm
6. Cross-group balances
7. Polish (activity feed, pagination)
8. AWS deployment (staging → prod)
