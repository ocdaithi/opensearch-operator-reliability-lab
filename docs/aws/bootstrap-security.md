# Bootstrap security and design

The account bootstrap deliberately uses ordinary Terraform and AWS identity
mechanisms. The installation begins with short-lived local state, creates the
durable S3 backend as a managed resource, and asks Terraform to migrate its own
state. This keeps the control flow visible to a maintainer who already
understands `terraform plan`, saved plans, `terraform apply` and backend
initialisation.

Terraform's backend and AWS provider both use the final credentials selected
through the normal AWS SDK credential chain. This ambient-credential model is
an explicit scope amendment for this change, not an incidental removal of a
Terraform variable.

The [account bootstrap runbook](account-bootstrap.md) is the only source of
executable bootstrap commands. This document explains the boundaries behind
that process.

## Why local state is acceptable initially

The permanent state bucket cannot be the backend before it exists. For the
first installation only, Terraform writes state to an ignored directory on a
trusted, encrypted workstation. The operator uses one private saved plan,
reviews it locally and applies that exact file. Local state, the saved plan and
backend metadata are handled as confidential material.

This is a bounded exposure, not a claim that local state is generally safe. It
is acceptable because the phase is short, single-operator and recoverable, and
because no lower-risk backend already exists. Recovery copies are retained
until the remote backend has passed a normal refresh-enabled zero-change plan.
The existing account has already migrated and must not repeat this phase.

## Why Terraform creates its own backend

CloudFormation is not used. Adding a second infrastructure engine solely to
create Terraform's backend would add another state model, permission surface
and recovery procedure. A temporary local backend solves the ordering problem
without creating a permanent second control plane.

Terraform's native backend migration is preferable to a repository script. It
uses Terraform's own backend knowledge, presents the migration for human
acceptance and keeps future behaviour aligned with the supported CLI. The
post-migration control is a fresh plan with normal refresh and detailed exit
codes. It checks the declared resources directly against AWS.

There is no DynamoDB lock table. The S3 backend uses `use_lockfile = true`, so
Terraform coordinates writers through the exact
`bootstrap/terraform.tfstate.tflock` object. A second database, permission set
and lifecycle are unnecessary for this small stack. Lock recovery still
requires proof that no Terraform process is active.

## Root-owned controls and temporary privilege

The root MFA session creates the bootstrap IAM user and two durable
customer-managed permissions boundaries. These controls stay outside
Terraform because they cap the roles that Terraform creates. Letting the
bounded roles update their own ceilings would make the boundary ineffective.
Terraform and the administration role can read the policies for verification
but cannot mutate them.

The temporary bootstrap policy also remains outside Terraform. Terraform
cannot create the authority required for its first apply. A root-created policy
therefore grants only the reviewed first-write actions, scoped to the exact
account, bucket, user, roles, budget and OIDC provider. Every allow statement is
bound to the bootstrap IAM principal, an AWS sign-in session and one literal
UTC expiry no more than four hours after rendering.

Expiry limits use after the deadline but does not remove the attached policy.
The administration role explicitly checks, detaches and deletes it after
migration and a zero-change plan. The bootstrap user retains only the AWS login
policy, MFA and the ability to assume the administration role. It has no access
keys, group permissions, inline policies or permissions boundary.

## State bucket controls

Terraform continues to manage the state bucket after migration. The resource
contract includes:

- `force_destroy = false` and `prevent_destroy` lifecycle protection;
- S3 Versioning for recovery from an unsafe current object version;
- SSE-S3 encryption at rest;
- all four S3 public-access-block settings;
- `BucketOwnerEnforced` object ownership;
- a bucket policy denying requests without HTTPS;
- retention of a bounded number and age of non-current versions;
- object permissions limited to the exact state and lock keys.

State readers may get and put the state object but do not receive state-object
delete permission. Lock deletion applies only to the exact native lockfile. The
bucket remains dedicated to this stack because some required bucket-level
operations can list object names.

Versioning provides recovery material, not an automatic rollback. Selecting an
older version requires a reviewed incident decision and authority outside the
routine role where necessary. `prevent_destroy` also reduces accidental loss,
but no Terraform lifecycle rule protects against the AWS account itself being
closed or root deliberately bypassing the design.

## Identity and trust boundaries

The trust path has four distinct identities:

1. The root user performs only root prerequisites with MFA and has no access
   keys.
2. `opensearch-lab-bootstrap` authenticates with `aws login`. Its temporary
   policy is usable only from the exact principal and AWS sign-in session.
3. `opensearch-lab-terraform-admin` is assumed from that login session for
   migration and later human foundation work. Its root-created boundary caps
   the Terraform-managed inline policy.
4. `opensearch-lab-github-actions` trusts GitHub's OIDC provider for one exact
   repository and Environment subject. Owner and repository numeric IDs make
   the subject resistant to name reuse, while the GitHub Environment restricts
   deployment to protected `main`.

GitHub repository and Environment protection settings are outside Terraform.
The AWS trust policy and GitHub deployment rules must both be correct. The OIDC
smoke workflow proves that the selected Environment can exchange a token for
temporary AWS credentials. It does not prove that every future workflow is
safe, and it stores no AWS access key.

The Terraform AWS provider uses the ambient AWS SDK credential chain. The
initial apply selects the `aws login` profile. Later operations select an AWS
CLI role profile whose source is that login profile. Credentials and role ARNs
are never Terraform input variables.

Each operation has one expected identity:

| Operation                                          | Required identity                                 |
| -------------------------------------------------- | ------------------------------------------------- |
| Root prerequisites                                 | Root with MFA; Terraform is not run               |
| Initial local backend initialisation               | `opensearch-lab-bootstrap` IAM user               |
| Initial saved plan and exact apply                 | `opensearch-lab-bootstrap` IAM user               |
| Native S3 migration                                | Assumed `opensearch-lab-terraform-admin` role     |
| Existing-backend compatibility and reconfiguration | Assumed `opensearch-lab-terraform-admin` role     |
| Routine local Terraform                            | Assumed `opensearch-lab-terraform-admin` role     |
| Credential-free validation                         | No AWS identity                                   |
| Current OIDC smoke test                            | State-only `opensearch-lab-github-actions` role   |
| Future GitHub Terraform                            | Deferred separately reviewed plan and apply roles |

The current OIDC smoke role can read and update only the exact state and lock
objects. It cannot refresh managed AWS resources, run a useful Terraform plan
or apply infrastructure.

### Ambient credentials are an explicit decision

The S3 backend authenticates before the AWS provider is configured. A provider
`assume_role` block therefore cannot select the identity used to read or lock
remote state. Retaining provider role assumption as the routine mechanism
would leave the backend on the bootstrap identity unless a separate backend
role-assumption configuration were also retained. That would restore two
credential paths with independent configuration and failure modes.

The decision is instead to select one final identity before invoking Terraform.
The backend and provider then use the same credentials:

- a fresh installation uses the exact `opensearch-lab-bootstrap` IAM user for
  its initial plan and exact saved-plan apply;
- native state migration and all routine workstation Terraform operations use
  the exact `opensearch-lab-terraform-admin` assumed-role identity;
- the current OIDC smoke workflow uses the exact
  `opensearch-lab-github-actions` assumed role; and
- any future GitHub Terraform workflow must assume its separately reviewed
  execution role through OIDC before starting Terraform.

This change neither adds that future role nor expands the current GitHub role.
Automated foundation apply remains deferred.

The provider's `allowed_account_ids` setting rejects credentials for another
AWS account. It does not prove that a same-account caller is the intended IAM
user or assumed role. Exact identity is therefore a procedural control. The
runbooks require an STS caller check immediately before every plan and apply,
native state migration and existing-account backend reconfiguration. A saved
plan does not bind the identity that later applies it.

Workstation setup keeps AWS configuration and login material in the ignored
repository-local paths selected by `AWS_CONFIG_FILE`,
`AWS_SHARED_CREDENTIALS_FILE` and `AWS_LOGIN_CACHE_DIRECTORY`. In every new
shell from the repository root, the operator restores them as
`$PWD/.aws/config`, `$PWD/.aws/credentials` and `$PWD/.aws/login/cache`, sets
`AWS_EC2_METADATA_DISABLED=true`, and preserves the existing ignored files.
Each Terraform command names the intended profile. Setup also clears competing
static credentials, web-identity settings, container credential settings,
inherited profile selectors, AWS endpoint overrides and inherited Terraform
CLI arguments before authentication. This prevents a higher-precedence
credential, endpoint or command setting from silently defeating the explicit
selection.

This model does not broaden an IAM policy or role trust. It moves role
selection from Terraform configuration into the operator's AWS CLI environment.
That creates an operator-error and recovery trade-off: a sufficiently
privileged wrong role in the same account could pass `allowed_account_ids`, and
lost or incorrect local profile configuration can block backend access. The
environment reset, explicit profile selection and adjacent exact STS checks
are the compensating controls. Restoring those local files is part of
workstation recovery, not an AWS configuration change.

### Existing S3-backed installation

The existing installation has already migrated to S3. Its first compatibility
plan on this branch must preserve its current ignored `backend.tf` and cached
backend metadata, including `.terraform/terraform.tfstate`, unchanged. It must
not run the fresh-install migration path.
The legacy backend may continue assuming the administration role for that
check while the provider receives an independently assumed administration-role
session from the ambient profile. Both paths are expected to end at
`opensearch-lab-terraform-admin`.

A zero-change result is the compatibility criterion, but it has not been
verified by this code-only work. Only after that result may the operator review
a separate local transition from the legacy backend role-assumption settings
to the partial ambient-credential backend. That transition changes local
backend configuration and cached metadata, not AWS role trust or managed
resource permissions. It must not be combined with state migration.

## Runtime inputs and public source

Tracked Terraform files contain declarations, validation and portable security
constants. Installation identity is injected at runtime through an ignored
private tfvars file. Terraform validates the expected account ID, Region,
bucket name, budget email, GitHub owner, repository, immutable numeric IDs and
Environment. It derives the AWS partition, bucket ARN, state and lock keys, and
predictable role and policy names. The current pre-Terraform policies and OIDC
audience support only the commercial `aws` partition, which Terraform enforces
before creating resources.

The tracked `terraform.tfvars.example` uses synthetic values and is safe to
publish. Real account IDs, bucket names, notification addresses, numeric GitHub
IDs and role ARNs are not tracked.

Future GitHub planning can map non-private configuration to Environment
variables and private configuration to Environment secrets, exposing both to
Terraform through `TF_VAR_*` environment variables. OIDC supplies temporary AWS
credentials separately. Backend configuration is passed to initialisation as
`bucket`, `key`, `region`, `encrypt` and `use_lockfile`; it contains no profile,
assume-role or credential settings.

Terraform's `sensitive` marker reduces display in selected CLI and UI contexts.
It does not encrypt a value or guarantee its absence from state or a saved plan.
State and binary plans can contain resolved private values, so both stay in
private storage and are never uploaded to GitHub.

## Why foundation apply remains manual

The account foundation creates its own state storage, human administration role
and GitHub federation boundary. It changes rarely and has a high consequence if
an incorrect plan is applied. The current custody model is therefore local
private plan, human review, exact local apply, refreshed zero-change plan, then
plan removal.

Credential-free GitHub Actions validation and the OIDC smoke test remain useful
without automating apply. Automated foundation apply is deferred until plan
custody, protected approval and recovery behaviour have a separate reviewed
design.

A future EKS workflow may plan from protected `main`, store the binary plan as
a private short-lived S3 object, expose only a redacted summary, wait for
protected Environment approval, apply the exact downloaded plan and rely on
lifecycle deletion. This is planned, not implemented. Argo CD will later
reconcile workloads inside EKS. It will not manage Terraform infrastructure.

## Known limitations and recovery boundary

- Root and GitHub Environment prerequisites are manual and can drift outside
  Terraform.
- The current policy templates and OIDC audience target only the commercial AWS
  partition.
- The first local state depends on the workstation's storage, access control
  and backup posture.
- AWS Budgets notifications can be delayed and do not enforce a hard cost cap.
- One standalone account provides less isolation than a multi-account design.
- A permissions boundary limits effective permissions but does not validate a
  role trust policy. Terraform tests, plan review and OIDC verification cover
  that separate trust surface.
- `allowed_account_ids` rejects the wrong AWS account but cannot distinguish
  the intended administration role from another same-account identity.
- Local Terraform relies on an explicitly selected profile and exact
  point-in-time STS caller checks. Terraform configuration does not enforce the
  caller ARN.
- A reviewed saved plan does not retain or enforce the identity used to apply
  it.
- S3 encryption is server-side. Anyone who can read authorised state plaintext
  can see resolved values.
- Native locking prevents ordinary concurrent writers but cannot distinguish a
  stale lock from an active operation without operator evidence.
- S3 version recovery and lost backend access can require root-supervised,
  case-specific recovery outside routine role permissions.
- A zero-change plan proves Terraform sees no current resource difference. It
  does not verify manual GitHub settings or guarantee that asynchronous budget
  email delivery has occurred.
- The routine administration role cannot change its IAM or OIDC security
  boundary or the HTTPS-only bucket policy. Those changes require a separate
  root-supervised review.

The [recovery guide](account-bootstrap-recovery.md) defines stop conditions and
case boundaries. It does not replace incident-specific review.

## Primary references

- [AWS IAM permissions boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
- [AWS root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
- [AWS Budgets best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html)
- [AWS S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [AWS S3 server-side encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html)
- [AWS S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [AWS S3 Object Ownership](https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform backend initialisation](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Terraform sensitive data in state](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
- [GitHub OIDC security](https://docs.github.com/en/actions/concepts/security/openid-connect)
- [GitHub deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
