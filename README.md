# KIND Cluster with Self-Hosted EKS Pod Identity Webhook

This repository provides a **Makefile** to set up a local [KIND](https://kind.sigs.k8s.io/) cluster and demonstrate a self-hosted **EKS Pod Identity Webhook**. It supplements the Medium article on configuring production-level authentication and authorization in homelab or on-prem Kubernetes clusters without manually rotating AWS access keys.

---

## Features

* Create and delete a KIND cluster with OIDC support
* Fetch OIDC discovery and JWKS from the cluster
* Create a publicly readable S3 bucket to host OIDC metadata
* Deploy IAM OIDC provider and test IAM role in AWS
* Install **Cert-Manager** and the **EKS Pod Identity Webhook**
* Deploy a test pod that assumes the IAM role via OIDC

---

## Prerequisites

* [KIND](https://kind.sigs.k8s.io/)
* [kubectl](https://kubernetes.io/docs/tasks/tools/)
* [AWS CLI](https://aws.amazon.com/cli/) with sufficient permissions
* [Helm](https://helm.sh/)
* [jq](https://stedolan.github.io/jq/)
* Optional: `.env` file to override defaults

---

## Usage

### 1. Configure environment variables

Create a `.env` file or use the defaults in the Makefile:

```env
CLUSTER_NAME=oidc
OIDC_ISSUER=oidc-kind.example.io
AWS_REGION=us-west-2
AWS_ACCOUNT_ID=YOUR_AWS_ACCOUNT
SA_NAMESPACE=default
SA_NAME=test-sa
```

---

### 2. Create the cluster and setup OIDC

Run the default Makefile target:

```bash
make
```

This executes the following steps:

1. **Create KIND cluster** using the OIDC-enabled configuration
2. **Fetch OIDC discovery and JWKS** from the cluster
3. **Create S3 bucket** and upload OIDC files
4. **Create IAM OIDC provider** in AWS
5. **Create test IAM role** and attach policy
6. **Install Cert-Manager** and the **EKS Pod Identity Webhook**
7. **Deploy test pod** to verify OIDC-based role assumption

---

### 3. Delete the cluster

```bash
make delete
```

---

### 4. Check cluster info

```bash
make info
```

---

### Notes

* The S3 bucket must be publicly readable to serve OIDC discovery documents. You may need to configure a CNAME pointing to the S3 bucket endpoint.
* The test pod runs the AWS CLI and verifies the role can be assumed via OIDC:

```bash
kubectl exec -n default aws-cli -- aws sts get-caller-identity
```

* Integrating these steps into an **IaC/GitOps workflow** (Terraform + ArgoCD/Flux) is recommended for production environments.

---

This Makefile demonstrates a **full self-hosted OIDC workflow**, perfect for homelab testing or on-prem Kubernetes setups without relying on EKS.
