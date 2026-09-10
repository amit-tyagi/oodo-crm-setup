# Odoo CRM on AWS — Architecture & Deployment Plan

## 1. Key Decisions & Assumptions

| Decision | Choice | Notes |
|---|---|---|
| IaC Tool | **AWS CloudFormation** | Native AWS, no state file to manage |
| AWS Auth in GitHub Actions | **Static credentials via GitHub Secrets** | Existing access key + secret key stored as repo secrets |
| CF Stack Strategy | **Separate stacks with CF Outputs + `Fn::ImportValue`** | Independent deployments, cross-stack references via exports |
| Large templates | **S3 bucket (optional)** | Only needed if a template exceeds the 51 KB CF inline limit |
| Change preview | **CloudFormation Change Sets** | Run via `infra-plan` workflow |
| Odoo Version | **18 Community** | Official `odoo:18` Docker image as base |
| Custom Addons | **None** | No custom Odoo modules; base image only |
| Odoo Image | **ECR** | Built from `odoo:18`, pushed to ECR |
| SSL/TLS | **None** | No custom domain; ALB DNS name used directly over HTTP |
| Secrets — DB credentials | **Existing Secrets Manager secret** | Already stored; ARN passed as a GitHub variable |
| Secrets — Odoo admin password | **New Secrets Manager secret** | Created in stack `04-secrets` |
| Aurora PostgreSQL | **Existing cluster** | Not created; connected via existing secret and SG ingress rule |
| Fargate capacity | **Spot with on-demand fallback** | Cost savings; on-demand tasks launch if Spot unavailable |
| Subnet layout | **GitHub variables** | VPC ID, subnet IDs passed via GitHub — not hardcoded in files |
| GitHub Actions triggers | **`workflow_dispatch` only** | All deployments are manual and intentional |

---

## 2. Architecture Overview

```
Browser / Client
      │
      ▼  HTTP port 80
ALB (public subnets)
ALB DNS name used directly — no custom domain, no HTTPS
      │
      ▼
Target Group (port 8069)
      │
      ▼
ECS Fargate Tasks (private subnets)
Spot capacity with on-demand fallback
      │             │
      ▼             ▼
Existing        EFS Mount
Aurora          (filestore)
PostgreSQL      (private subnets)
```

> **Note:** Without HTTPS, session data and credentials travel over HTTP. For hardened access consider placing the ALB behind a corporate VPN or adding a custom domain with ACM later.

---

## 3. Custom Addons — What They Are

Odoo addons are modules (plugins) that extend Odoo's functionality beyond the built-in apps. Examples: custom invoice layouts, bespoke CRM fields, third-party integrations. Since there are none, the Dockerfile uses the official `odoo:18` base image with only environment-level configuration applied. If addons are needed in future, they are copied into the image at build time.

---

## 4. Using the Existing Aurora PostgreSQL Cluster

No Aurora infrastructure is created. The existing cluster is consumed as a dependency.

### Values Required Before Deployment

Stored as **GitHub variables and secrets**:

| GitHub Variable | Value |
|---|---|
| `AURORA_WRITER_ENDPOINT` | Writer endpoint hostname from RDS Console |
| `AURORA_PORT` | `5432` |
| `AURORA_DB_NAME` | Odoo database name on the existing cluster (e.g. `odoo_crm`) |
| `AURORA_SECRET_ARN` | ARN of the existing Secrets Manager secret holding DB credentials |
| `EXISTING_AURORA_SG_ID` | Security group ID attached to the existing Aurora cluster |

### Pre-Flight: One-Time Manual Step (DBA)

Run the following against the existing cluster if the Odoo database and user do not yet exist:

```sql
CREATE DATABASE odoo_crm;
CREATE USER odoo_user WITH PASSWORD '...';
GRANT ALL PRIVILEGES ON DATABASE odoo_crm TO odoo_user;
```

Update the existing Secrets Manager secret to include these credentials if not already present.

### Security Group Access

The `03-security-groups` stack adds a standalone `AWS::EC2::SecurityGroupIngress` resource to the existing Aurora SG, permitting port 5432 from the new `odoo-ecs-sg`. No other changes are made to the existing Aurora SG. The rule is CF-managed and visible in drift detection.

---

## 5. Fargate Spot Capacity Strategy

The ECS Service uses a **capacity provider strategy**:

| Provider | Base | Weight | Behaviour |
|---|---|---|---|
| `FARGATE_SPOT` | 0 | 4 | Preferred; used for most tasks |
| `FARGATE` | 1 | 1 | Fallback; at least 1 on-demand task always running |

This ensures at least one on-demand task is always available, with Spot tasks handling the remaining capacity. If a Spot interruption occurs, ECS replaces the task automatically.

---

## 6. AWS Resources to Create

### ECR — `01-ecr.yaml`
- Repository: `odoo-crm`
- Image scanning on push: enabled
- Lifecycle policy: retain last 10 tagged images
- **Exports:** `OdooEcrRepositoryUri`

### IAM Roles — `02-iam.yaml`
| Role | Purpose |
|---|---|
| ECS Task Execution Role | Pull from ECR, write CloudWatch logs, read Secrets Manager |
| ECS Task Role | Access EFS and Secrets Manager at runtime |

- **Exports:** `OdooTaskExecutionRoleArn`, `OdooTaskRoleArn`

### Security Groups — `03-security-groups.yaml`
**Parameters (from GitHub variables):** VPC ID, existing Aurora SG ID

| SG Name | Inbound Rule | Purpose |
|---|---|---|
| `odoo-alb-sg` | 80 from `0.0.0.0/0` | ALB HTTP access |
| `odoo-ecs-sg` | 8069 from `odoo-alb-sg` | Fargate tasks |
| `odoo-efs-sg` | 2049 from `odoo-ecs-sg` | EFS mount targets |
| *(existing Aurora SG)* | 5432 from `odoo-ecs-sg` via `SecurityGroupIngress` | ECS → Aurora access |

- **Exports:** `OdooAlbSgId`, `OdooEcsSgId`, `OdooEfsSgId`

### Secrets — `04-secrets.yaml`
- Creates Secrets Manager secret: `odoo/admin-password`
- Aurora DB credentials secret already exists — its ARN passed in via GitHub variable
- **Exports:** `OdooAdminSecretArn`

### EFS — `05-efs.yaml`
**Imports:** `OdooEfsSgId`

- EFS file system with encryption at rest
- Mount targets in each private subnet (one per AZ)
- EFS Access Point: path `/odoo/filestore`, UID/GID `1000` (Odoo process user)
- Backup policy: enabled
- **Exports:** `OdooEfsId`, `OdooEfsAccessPointArn`

### ALB — `06-alb.yaml`
**Imports:** `OdooAlbSgId`
**Parameters (from GitHub variables):** public subnet IDs

- Internet-facing ALB in existing public subnets
- Listener port 80: forward to target group (HTTP only — no custom domain)
- Target group: HTTP port 8069, health check on `/web/health`
- Session stickiness: enabled (Odoo requires it)
- Idle timeout: 60 seconds (Odoo longpolling)
- **Exports:** `OdooAlbArn`, `OdooTargetGroupArn`, `OdooAlbDnsName`

### ECS — `07-ecs.yaml`
**Imports:** `OdooTaskExecutionRoleArn`, `OdooTaskRoleArn`, `OdooEcsSgId`, `OdooAdminSecretArn`, `OdooEfsId`, `OdooEfsAccessPointArn`, `OdooTargetGroupArn`
**Parameters (from GitHub variables):** private subnet IDs, Aurora writer endpoint, Aurora port, Aurora DB name, Aurora secret ARN, Odoo image URI, ECS desired count, ECS task CPU, ECS task memory

- **ECS Cluster** with Fargate + Fargate Spot capacity providers
- **Task Definition:**
  - Container: `odoo:18` image from ECR
  - CPU / Memory: from `ECS_TASK_CPU` / `ECS_TASK_MEMORY` GitHub variables (defaults: `2048` / `4096`)
  - Non-sensitive env vars: `DB_HOST`, `DB_PORT`, `DB_NAME`
  - Secrets from Secrets Manager: DB password (existing secret), admin password
  - EFS volume mounted at `/var/lib/odoo`
  - Log driver: `awslogs` → CloudWatch Log Group
- **ECS Service:**
  - Desired count: from `ECS_DESIRED_COUNT` GitHub variable (default: `1`)
  - Capacity provider strategy: Spot (weight 4) + on-demand fallback (base 1)
  - Rolling deployment: `minimumHealthyPercent: 50`, `maximumPercent: 200`
  - Registered to ALB target group
  - Auto-scaling: target tracking on CPU (70%) and Memory (70%)
- **CloudWatch Log Group:** `/ecs/odoo-crm`, 30-day retention
- **Exports:** `OdooEcsClusterArn`, `OdooEcsServiceName`

---

## 7. CloudFormation Stack Structure

```
cloudformation/
├── stacks/
│   ├── 01-ecr.yaml
│   ├── 02-iam.yaml
│   ├── 03-security-groups.yaml
│   ├── 04-secrets.yaml
│   ├── 05-efs.yaml
│   ├── 06-alb.yaml
│   └── 07-ecs.yaml
└── parameters/
    └── parameters.json          ← non-sensitive defaults only
```

> Sensitive values (subnet IDs, VPC ID, Aurora endpoint, secret ARNs, SG IDs) are stored as **GitHub variables and secrets** — not committed to the repo.

### Deployment Order & Parallelism

```
01-ecr + 02-iam (parallel)
   │
   ▼
03-security-groups + 04-secrets (parallel)
   │
   ▼
05-efs + 06-alb (parallel)
   │
   ▼
07-ecs
```

---

## 8. Repository File Structure

```
oodo-crm-setup/
├── .github/
│   └── workflows/
│       ├── infra-plan.yml       # Manual: create change sets, post diff summary
│       ├── infra-apply.yml      # Manual: deploy all CF stacks in order
│       └── app-deploy.yml       # Manual: build image → push ECR → update ECS
├── cloudformation/
│   ├── stacks/
│   │   ├── 01-ecr.yaml
│   │   ├── 02-iam.yaml
│   │   ├── 03-security-groups.yaml
│   │   ├── 04-secrets.yaml
│   │   ├── 05-efs.yaml
│   │   ├── 06-alb.yaml
│   │   └── 07-ecs.yaml
│   └── parameters/
│       └── parameters.json
├── docker/
│   ├── Dockerfile               # Based on odoo:18
│   └── odoo.conf                # Odoo config
└── PLAN.md
```

---

## 9. GitHub Actions Workflows

All workflows use `workflow_dispatch` — every deployment is manual and intentional.

### Phase 0: One-Time Manual Setup (no workflow needed)

| Step | Action |
|---|---|
| 1 | Store `AWS_ACCESS_KEY_ID` in GitHub repository secrets |
| 2 | Store `AWS_SECRET_ACCESS_KEY` in GitHub repository secrets |
| 3 | Store `AWS_REGION` in GitHub repository secrets |
| 4 | Add the following variables and secrets to the GitHub repository |

**GitHub Variables (non-sensitive):**

| Variable | Default | Description |
|---|---|---|
| `VPC_ID` | — | Existing VPC ID |
| `PUBLIC_SUBNET_IDS` | — | Comma-separated public subnet IDs (for ALB) |
| `PRIVATE_SUBNET_IDS` | — | Comma-separated private subnet IDs (for ECS, EFS) |
| `EXISTING_AURORA_SG_ID` | — | Security group ID of the existing Aurora cluster |
| `AURORA_WRITER_ENDPOINT` | — | Aurora writer endpoint hostname |
| `AURORA_PORT` | `5432` | Aurora port |
| `AURORA_DB_NAME` | — | Odoo database name on the existing cluster |
| `ECS_DESIRED_COUNT` | `1` | Number of Fargate tasks to run |
| `ECS_TASK_CPU` | `2048` | Task CPU units |
| `ECS_TASK_MEMORY` | `4096` | Task memory in MB |

**GitHub Secrets (sensitive):**

| Secret | Description |
|---|---|
| `AURORA_SECRET_ARN` | ARN of the existing Secrets Manager secret for DB credentials |

---

### `infra-plan.yml` — Preview Infrastructure Changes

**Trigger:** `workflow_dispatch`

**Steps:**
1. Configure AWS credentials from GitHub Secrets
2. Load variables from the GitHub repository
3. For each stack in dependency order: `aws cloudformation create-change-set`
4. Describe each change set and format the resource diff
5. Print combined diff to the workflow run summary
6. Delete the change sets (nothing is applied — review only)

---

### `infra-apply.yml` — Deploy Infrastructure

**Trigger:** `workflow_dispatch`

**Steps:**
1. Configure AWS credentials from GitHub Secrets
2. Load variables from the GitHub repository
3. Deploy stacks in order using `aws cloudformation deploy --capabilities CAPABILITY_NAMED_IAM`:
   ```
   01-ecr + 02-iam (parallel)
   → 03-security-groups + 04-secrets (parallel)
   → 05-efs + 06-alb (parallel)
   → 07-ecs
   ```
4. Fail fast if any stack enters rollback; surface the CF error in the run log

---

### `app-deploy.yml` — Build and Deploy Odoo Application

**Trigger:** `workflow_dispatch`
**Inputs:**
- `image_tag` — optional; defaults to the Git SHA of the selected branch

**Steps:**
1. Configure AWS credentials from GitHub Secrets
2. Load variables from the GitHub repository
3. Build Docker image from `docker/Dockerfile` (based on `odoo:18`)
4. Push to ECR with tags: `{image_tag}` and `latest`
5. Update `07-ecs` stack with the new image URI parameter (triggers rolling ECS deployment)
6. Wait for ECS service to reach steady state (`ecs wait services-stable`)

---

## 10. Deployment Phases

| Phase | Resources | How |
|---|---|---|
| **Phase 0** — Bootstrap | GitHub variables and secrets; Aurora pre-flight SQL if DB/user not yet created | Manual |
| **Phase 1** — Foundation | Stacks 01–04: ECR, IAM, Security Groups, Secrets Manager | `infra-apply` workflow |
| **Phase 2** — Storage | Stack 05: EFS + mount targets + access point | `infra-apply` workflow |
| **Phase 3** — Compute | Stacks 06–07: ALB + ECS Cluster + Service | `infra-apply` workflow |
| **Phase 4** — App | Build `odoo:18` image, push to ECR, ECS rolling deploy | `app-deploy` workflow |
