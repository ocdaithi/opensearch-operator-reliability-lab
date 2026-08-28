# Account bootstrap recovery

This guide defines recovery boundaries for the account foundation. It does not
replace incident-specific review and does not provide a second bootstrap
command sequence. Use the [canonical account bootstrap runbook](account-bootstrap.md)
for commands after the recovery decision is made.

## Recovery principles

- Stop at the first unexpected result. Preserve local state, saved plans,
  backend declarations, backend metadata and relevant terminal output in
  private storage.
- Prevent concurrent Terraform work until the authoritative backend and lock
  status are understood.
- Do not retry a saved plan or migration blindly.
- Do not alter state or delete remote state objects.
- Treat an S3 migration that may have written state as committed until evidence
  shows otherwise.
- Do not disclose state, plan contents, account identifiers or private policy
  documents in issues or workflow logs.
- Resume only through a newly reviewed plan or the runbook's native migration
  and refreshed zero-change checks.

## Failed initial apply

Terraform can update local state before an apply reports failure. Keep the
saved plan, local state, local backend declaration and `.terraform` backend
metadata unchanged. Record the failed resource and error without publishing
resolved values.

Do not reuse the saved plan automatically. Establish whether AWS created or
changed any resource and fix the underlying cause. A subsequent attempt must
start with a fresh plan against the retained local backend and current AWS
objects. Review that new plan in full. Migration is not allowed until the apply
has completed and Terraform can read the expected state-bucket and role
outputs.

If the failure involves an unexpected pre-existing resource, stop. Import,
adoption, deletion or renaming requires a separate architectural and security
review.

## Failed native migration before commit

A cancelled prompt or failure before any S3 state version is created leaves the
local backend authoritative. Preserve the recovery copies and Terraform's
diagnostic. Confirm that no remote state or native lock object was written and
that cached backend metadata still identifies the local source before deciding
to proceed.

After the cause is fixed and absence of a remote write is established, a peer
should review a return to the runbook's native migration step. Do not change
migration semantics, automate retries or replace Terraform's native process.

## Migration may have committed

If Terraform may have created an S3 state version, treat S3 as authoritative.
Keep the partial S3 backend declaration, cached metadata and all local recovery
copies. Do not reactivate the local backend, rerun the migration or delete the
S3 object.

Use Terraform's diagnostic together with S3 object and version metadata to
establish whether a current remote state exists. This is an existence and
authority decision. If the write committed, complete only the reviewed S3
backend initialisation path and require a normal refresh-enabled plan. Exit code
`0` is the recovery success condition. Any planned change must be understood and
handled through a new saved plan.

If authority remains ambiguous, stop and obtain a second review. Keeping both
copies untouched is safer than allowing two writers.

## Lost local recovery files

If remote migration and the refreshed zero-change plan were already confirmed,
the current versioned S3 object is authoritative. Reconstruct only the ignored
private inputs and partial backend declaration from approved records, then use
the routine S3 initialisation path in the runbook.

If verification had not completed, loss of the local state or backend metadata
removes important evidence. Stop normal work. Check approved encrypted backups
and S3 object-version metadata. Do not manufacture a replacement state, assume
that an empty backend is safe or use a plan as state. Reconstruction or import
requires a separate, resource-by-resource recovery plan.

## S3 object-version recovery

S3 Versioning preserves earlier state object versions, subject to the configured
non-current-version retention. Freeze Terraform activity and identify the last
known good version using timestamps, incident context and the corresponding
configuration revision. A plan file is not a valid substitute for state.

Routine roles deliberately lack broad version-management permissions. Recovery
may therefore need a root-supervised or separately approved break-glass session.
Restore the selected content as a new current version so the version history is
preserved. Do not permanently delete versions or bypass the bucket's encryption,
ownership, public-access or HTTPS controls.

After restoration, initialise the reviewed S3 backend and require a refreshed
plan. Investigate every proposed change before allowing another apply.

## Backend access loss

First distinguish credential expiry from an authorisation or backend problem.
An expired `aws login` session is resolved by re-authentication, followed by
assumption of the existing administration role. It is not a reason to edit the
backend.

If role assumption fails, inspect the exact source principal, MFA-backed login
session, role trust policy, inline policy and root-created permissions boundary.
If S3 access alone fails, inspect the exact bucket, Region, state key, native
lock key and bucket policy. Do not weaken public-access blocking, HTTPS
enforcement or the permissions boundary to make a diagnostic pass.

Changes to a durable boundary require root authority and a separate reviewed
security decision. Restore the documented contract, then run a refreshed plan.

## Stale native lockfile

A lock is stale only when there is positive evidence that no Terraform process,
workflow or operator still owns it. Record the lock identity and check with all
possible operators before intervening.

Use Terraform's native force-unlock mechanism only with the exact lock ID and a
reviewed decision. Do not delete the `.tflock` object directly through S3. If
ownership is uncertain, wait or escalate rather than risk two concurrent state
writers. Run a refreshed plan after recovery.

## Temporary-policy expiry

The literal UTC expiry stops new allowed actions but leaves the managed policy
attached. Preserve any partial Terraform state and establish which bootstrap
phase completed. Do not edit the policy, extend its expiry or create a new
version.

Using a root MFA session, remove the expired attachment and delete the expired
policy. Generate and attach a fresh policy only for an approved recovery after
the partial state and next plan have been reviewed. The new policy still has a
maximum four-hour lifetime. Never leave two temporary bootstrap policies in
place.

## OIDC verification failure

OIDC verification happens after state migration and temporary-policy removal.
Do not recreate temporary bootstrap access to fix it.

Check the failed workflow's selected Environment, protected-branch eligibility,
`id-token: write` permission, Environment Region variable and role ARN secret.
Then compare the AWS role trust to the exact issuer, audience and immutable
owner, repository and Environment subject. GitHub repository and Environment
settings are manual controls; AWS trust is Terraform-managed.

Repair a Terraform-owned difference only through the routine saved-plan process.
Repair a GitHub setting through a reviewed manual change. Dispatch a new smoke
test only after the failed run and its cause are understood.

## Primary references

- [Terraform backend initialisation and migration](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Terraform force-unlock](https://developer.hashicorp.com/terraform/cli/commands/force-unlock)
- [Terraform state recovery with S3 Versioning](https://developer.hashicorp.com/terraform/language/backend/s3#s3-bucket-versioning)
- [AWS S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [AWS IAM troubleshooting](https://docs.aws.amazon.com/IAM/latest/UserGuide/troubleshoot.html)
- [GitHub OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
