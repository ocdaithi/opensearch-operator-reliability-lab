# opensearch-operator-reliability-lab

A public, independently developed open-source lab for validating the OpenSearch Kubernetes Operator on short-lived Amazon EKS environments.

The planned platform combines Terraform, GitHub Actions OIDC, repeatable reliability tests and curated diagnostic evidence. Human and automated project access will use temporary AWS credentials; long-lived AWS access keys will not be used.

The project is in account bootstrap and infrastructure design. No AWS infrastructure or test workload has been provisioned. Curated documentation and results will later be published through GitHub Pages from a generated site artefact containing only selected public material.

- [AWS account bootstrap](docs/aws/account-bootstrap.md)
- [Architecture decisions](docs/adr/)
