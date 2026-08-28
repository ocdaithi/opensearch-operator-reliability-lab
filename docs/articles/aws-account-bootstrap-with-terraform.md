# Bootstrapping a Secure AWS Account with Terraform and GitHub Actions

**Publication excerpt:** A practical design for creating Terraform's own secure
AWS backend, removing bootstrap privilege and adding GitHub OIDC without a
second infrastructure engine or long-lived access keys.

**Suggested URL slug:** `secure-aws-account-bootstrap-terraform-github-actions`

**Tags:** Terraform, AWS, GitHub Actions, DevSecOps, Platform Engineering

Every Terraform project eventually reaches an awkward question: what creates
the infrastructure that Terraform itself needs?

For an AWS reliability lab, that question covered more than an S3 bucket. The
foundation also needed a human administration role, a GitHub Actions OIDC
identity, a budget, permissions boundaries and a safe path for removing the
privilege used to create them. The project had to remain understandable to a
new open-source maintainer, avoid long-lived AWS access keys and keep private
installation values out of a public repository.

The resulting design uses a short local-first phase and Terraform's native
backend migration:

> Prepare private inputs, create reviewed pre-Terraform policies, authenticate
> with `aws login`, apply one reviewed saved plan to local state, migrate
> natively to S3, require a refreshed zero-change plan, remove temporary access,
> then verify GitHub OIDC.

That sequence is intentionally ordinary. Terraform owns infrastructure.
Root-owned IAM policies establish the ceiling. AWS CLI profiles supply temporary
credentials. GitHub proves federation but does not yet apply the foundation.

## Start with the account boundary

This lab uses a standalone AWS account to isolate experiments from personal or
employer infrastructure. A dedicated account is not the same as a full
multi-account landing zone, but it gives an open-source test environment a
clear billing, identity and teardown boundary.

The account also uses AWS Free Tier credits. AWS documents that joining an AWS
Organization or setting up AWS Control Tower can change the account plan and
cause remaining credits to expire. The project therefore keeps the account
standalone while those credits are relevant. That decision does not extend
their lifetime or prevent workloads from consuming them.

Cost alerts are an early foundation resource, not a later improvement. They
help make spend visible before EKS exists. They are still only notifications:
they can be delayed, they do not stop resources and they do not replace
lifecycle controls on expensive infrastructure.

## Root is a prerequisite, not a runtime identity

The root user has a narrow job. Before bootstrap, a maintainer confirms a unique
root password, working MFA and recovery paths, current security contacts and no
root access keys. Root then creates the few controls that cannot safely be
owned by the system they constrain.

Those controls are:

- an MFA-protected bootstrap IAM user that can authenticate through `aws login`;
- a durable permissions boundary for the human Terraform administration role;
- a separate durable boundary for the GitHub Actions role;
- one temporary bootstrap policy with an absolute expiry.

Root credentials never enter a terminal, a Terraform variable or GitHub. Once
the prerequisites exist, the root session ends.

This separation matters. A role cannot provide a meaningful security ceiling
if it can also update the permissions boundary that defines that ceiling. The
boundaries are created from tracked policy templates, resolved privately for
the exact account and state bucket, and reviewed before root creates them.
Terraform later attaches them to predictable roles but has only read-back
access to the boundary policies.

## Temporary privilege should be narrow in space and time

The first Terraform apply needs permission to create its state bucket, roles,
budget and OIDC provider. That authority cannot come from a role that does not
exist yet.

The bootstrap policy resolves this circular dependency without an access key.
It is bound to the exact bootstrap IAM principal and an AWS sign-in session. Its
resources name the exact account, bucket, roles, budget and OIDC provider. Every
allow statement shares one literal UTC expiry, with a maximum four-hour
lifetime.

The maintainer signs in using AWS CLI's browser-based `aws login` flow and the
IAM user's MFA session. The temporary policy authorises that session, not a
credential copied into a file. After bootstrap, the Terraform administration
role is assumed from the login profile through a normal AWS CLI role profile.
Both the S3 backend and AWS provider use the standard AWS SDK credential chain.

Expiry is a backstop, not cleanup. An expired managed policy can remain
attached, which creates ambiguity and invites unsafe reuse. The process
therefore checks the bootstrap user, detaches the policy and deletes it after
remote verification. The user finishes with no access keys, groups, inline
policies or boundary, and retains only the login policy needed to assume the
administration role.

## Parameterise identity without publishing it

Public Terraform source should describe a reusable security contract, not one
installation.

The tracked configuration declares inputs for the expected AWS account ID,
Region, state bucket, private budget email, GitHub owner, repository and
Environment. It also accepts the owner's and repository's immutable numeric
IDs, which strengthen the OIDC subject against name reuse. Terraform derives
the AWS partition, exact bucket ARN, role and policy names, and fixed state and
lock keys. This implementation deliberately supports only the commercial AWS
partition because the reviewed bootstrap policies and GitHub OIDC audience are
commercial-partition contracts.

Local installation values live in an ignored private tfvars file copied from a
fully synthetic example. The AWS provider restricts itself to the expected
account. Credentials, profiles and role ARNs are never Terraform inputs.

This distinction is easy to miss: a `.tf` file is not unsafe merely because it
declares an account ID variable. The disclosure happens when resolved private
values are committed, printed or uploaded. Declarations, validation and
portable constants belong in source control. Installation identity does not.

Marking the budget email as sensitive helps Terraform suppress it in some
output. It does not remove the value from state or a binary plan. Both artefacts
must still be treated as confidential.

## Let the first apply be local

Before the S3 bucket exists, the configuration uses Terraform's local backend
in an ignored private directory. The maintainer creates a binary plan there,
reviews its complete human-readable form and applies that exact saved file.

This approach accepts a brief local-state risk. It is reasonable for a
single-operator first installation on an encrypted workstation because it
avoids adding a permanent second infrastructure system. The local state, plan,
backend declaration and backend metadata remain private recovery evidence until
the S3 migration has been verified.

CloudFormation was considered unnecessary. Using it only to create Terraform's
backend would introduce another template language, state model, permission set
and recovery path. The local-first phase handles the ordering problem directly,
then disappears from routine operations.

## Use Terraform's migration rather than reimplementing it

After the first apply, Terraform exposes the created bucket name. The
maintainer preserves private recovery copies, replaces the local backend
declaration with a genuinely partial S3 declaration, and supplies the bucket,
fixed key, Region, encryption and native lockfile settings during backend
initialisation.

Terraform presents its own migration prompt. The maintainer reviews and accepts
it. Terraform remains the sole migration authority, with no repository wrapper
or parallel migration protocol.

The decisive verification is whether Terraform, using the S3 backend and
refreshed AWS data, produces a normal plan with no changes. Only exit code zero
permits temporary access removal and saved-plan deletion.

This is a useful general principle: use a tool's supported recovery and
migration semantics where they exist. Custom orchestration should be reserved
for a responsibility the native tool genuinely cannot express.

## Protect state without creating another database

The state bucket remains a Terraform-managed resource after migration. Its
contract includes versioning, SSE-S3, blocked public access,
`BucketOwnerEnforced` ownership, an HTTPS-only bucket policy, non-current
version retention and both `force_destroy = false` and Terraform lifecycle
protection.

Permissions distinguish the state object from its lock. The exact state key can
be read and replaced but not deleted by routine identities. The exact lock key
adds delete permission because releasing a lock requires it. The bucket is
dedicated to this foundation.

There is no DynamoDB table. Terraform's S3 backend supports a native lockfile,
which is sufficient for this stack and removes another resource, permission
surface and failure mode. Versioning supplies recovery material if a bad state
write becomes current. It does not make rollback automatic: selecting an older
version remains a reviewed incident action.

## OIDC proves identity without storing an AWS key

Terraform creates the GitHub OIDC provider and a bounded GitHub Actions role.
The trust policy pins the audience and exact repository Environment subject,
including immutable owner and repository identity. The GitHub Environment is a
second control plane: it admits only protected `main`, and its settings remain
outside Terraform.

The current smoke workflow requests `id-token: write`, exchanges GitHub's OIDC
token for short-lived AWS credentials and checks its caller identity without
printing it. The role ARN is installation configuration stored in the protected
Environment, not an AWS secret key.

This test answers a narrow but important question: can the reviewed workflow on
the reviewed branch assume the intended bounded role? It does not authorise
automated foundation changes.

## Human-reviewed plans remain the right trade-off

The account foundation is small, security-sensitive and rarely changed. For
now, each supported change follows the same custody model as bootstrap: a
private local plan, human review, exact local apply, refreshed zero-change plan,
then plan removal. Saved plans are never uploaded to GitHub. The durable
administration boundary intentionally excludes IAM, OIDC trust and bucket-policy
mutation. Changes to those contracts require a separate root-supervised
bootstrap and security review.

GitHub Actions still adds substantial value. It formats and validates Terraform,
runs mocked native tests, tests the focused policy renderers, checks repository
privacy safeguards and verifies immutable action pins without AWS credentials.
The OIDC smoke test is separate and explicitly dispatched.

Automated foundation apply is deferred because secure plan custody deserves its
own design. A binary Terraform plan can contain private values and should not be
treated as a harmless CI artefact.

For future EKS automation, the intended direction is different: plan only from
protected `main`, place the exact binary plan in a private short-lived S3
object, expose only a redacted workflow summary, require protected Environment
approval, apply the exact downloaded plan and rely on lifecycle deletion. That
workflow does not exist yet.

Argo CD has a later, separate role. Once EKS exists, it can reconcile Kubernetes
workloads inside the cluster. It will not apply Terraform or own AWS account
infrastructure.

## A reusable pattern for open-source infrastructure

The useful part of this design is not the project's names. It is the division
of responsibility:

- root establishes a small immutable ceiling;
- a short-lived human session creates Terraform's durable control plane;
- Terraform migrates itself using native behaviour;
- a refreshed plan verifies remote authority;
- temporary privilege is explicitly removed;
- OIDC proves automation identity without an AWS access key;
- CI validates source before it is trusted with apply.

Open-source projects can reuse that pattern for bounded test accounts, preview
environments or contributor labs. They should parameterise installation
identity, keep resolved values private, tailor the permission contracts to
their own services and preserve the distinction between Terraform
infrastructure and workload reconciliation.

The best bootstrap is not the most clever one. It is the one a new maintainer
can audit using the tools' standard concepts, recover without hidden state
machines and eventually simplify again.

## Official references

- [AWS Free Tier FAQ](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-FAQ.html)
- [AWS root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
- [AWS CLI sign-in with `aws login`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [AWS IAM permissions boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
- [AWS Budgets best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html)
- [AWS S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [AWS S3 server-side encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/serv-side-encryption.html)
- [AWS S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [Terraform S3 backend and lockfiles](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform backend initialisation](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Terraform saved plan mode](https://developer.hashicorp.com/terraform/cli/commands/apply#saved-plan-mode)
- [Terraform sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
- [GitHub OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [GitHub OIDC claims reference](https://docs.github.com/en/actions/reference/security/oidc)
- [GitHub deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
