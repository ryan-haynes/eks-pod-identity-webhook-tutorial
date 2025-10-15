# Makefile for KIND cluster

# Load .env file if it exists
ifneq (,$(wildcard .env))
    include .env
    export $(shell sed 's/=.*//' .env)
endif

CLUSTER_NAME ?= oidc

OIDC_ISSUER ?= oidc-kind.example.io
OIDC_PROVIDER_NAME ?= oidc-kind-provider
OIDC_DIR ?= oidc_bucket

POLICY_NAME ?= HelloOidcKind
ROLE_NAME ?= oidc-kind-role
SA_NAMESPACE ?= default
SA_NAME ?= test-sa

AWS_REGION ?= us-west-2
AWS_ACCOUNT_ID ?= YOUR_AWS_ACCOUNT

# Default target
.PHONY: all
all: create fetch-oidc create-bucket copy-oidc create-oidc-provider create-test-role install-webhook

# Create the KIND cluster
.PHONY: create
create:
	@echo "Creating KIND cluster: $(CLUSTER_NAME)"
	export OIDC_ISSUER=$(OIDC_ISSUER) && \
	envsubst < ./manifests/kind-config.yaml > /tmp/kind-config.yaml
	kind create cluster --name $(CLUSTER_NAME) --config /tmp/kind-config.yaml

# Delete the KIND cluster
.PHONY: delete
delete:
	@echo "Deleting KIND cluster: $(CLUSTER_NAME)"
	kind delete cluster --name $(CLUSTER_NAME)

# Get cluster info
.PHONY: info
info:
	@echo "Getting cluster info for $(CLUSTER_NAME)"
	kubectl cluster-info --context kind-$(CLUSTER_NAME)
	kubectl get nodes

# Fetch OIDC discovery and JWKS, rewrite jwks_uri
.PHONY: fetch-oidc
fetch-oidc:
	@mkdir -p $(OIDC_DIR)/.well-known
	@echo "Fetching OIDC discovery from cluster..."
	kubectl get --raw /.well-known/openid-configuration \
	| jq '.jwks_uri = "https://$(OIDC_ISSUER)/openid/v1/jwks"' \
	> $(OIDC_DIR)/.well-known/openid-configuration

	@mkdir -p $(OIDC_DIR)/openid/v1
	kubectl get --raw /openid/v1/jwks > $(OIDC_DIR)/openid/v1/jwks


.PHONY: create-bucket
create-bucket:
	@echo "Creating public S3 bucket $(OIDC_ISSUER) in region $(AWS_REGION)..."
	aws s3api create-bucket \
		--bucket $(OIDC_ISSUER) \
		--region $(AWS_REGION) \
		$(if $(filter us-east-1,$(AWS_REGION)),, --create-bucket-configuration LocationConstraint=$(AWS_REGION)) \
	|| true

	@echo "Disabling block public access..."
	aws s3api put-public-access-block \
		--bucket $(OIDC_ISSUER) \
		--public-access-block-configuration BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false

	@echo "Applying public-read bucket policy..."
	export OIDC_ISSUER=$(OIDC_ISSUER) && \
	envsubst < ./policies/public-read.json > /tmp/public-read.json

	aws s3api put-bucket-policy \
		--bucket $(OIDC_ISSUER) \
		--policy file:///tmp/public-read.json
	@echo "Bucket $(OIDC_ISSUER) is now publicly readable."
	@echo "Please create a CNAME ${OIDC_ISSUER} => https://$(OIDC_ISSUER).s3.$(AWS_REGION).amazonaws.com"
	@read -p "Enter to continue after creating dns..." continue;

.PHONY: copy-oidc
copy-oidc:
	aws s3 sync $(OIDC_DIR) s3://$(OIDC_ISSUER)

.PHONY: create-oidc-provider
create-oidc-provider:
	@echo "Getting OIDC issuer thumbprint..."
	thumbprint=$$(echo | openssl s_client -showcerts -connect $(OIDC_ISSUER):443 2>/dev/null \
		| openssl x509 -fingerprint -sha1 -noout \
		| cut -d'=' -f2 | tr -d ':'); \
	echo "Thumbprint: $$thumbprint"; \
	echo "Creating IAM OIDC provider..."; \
	aws iam create-open-id-connect-provider \
		--url https://$(OIDC_ISSUER) \
		--client-id-list sts.amazonaws.com \
	 	--thumbprint-list $$thumbprint \
	 	|| echo "OIDC provider may already exist, continuing..."

.PHONY: create-test-role
create-test-role:
	@echo "=== Step 1: Create minimal Hello World policy ==="; \
	policy_arn=$$(aws iam create-policy \
		--policy-name $(POLICY_NAME) \
		--policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sts:GetCallerIdentity","Resource":"*"}]}' \
		--query 'Policy.Arn' --output text 2>/dev/null || echo "arn:aws:iam::$(AWS_ACCOUNT_ID):policy/$(POLICY_NAME)"); \
	echo "Policy ARN: $$policy_arn"; \
	echo "=== Step 2: Create IAM role assumable via OIDC ==="; \
	aws iam create-role \
		--role-name $(ROLE_NAME) \
		--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::$(AWS_ACCOUNT_ID):oidc-provider/$(OIDC_ISSUER)"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"'"$(OIDC_ISSUER)"':sub":"system:serviceaccount:$(SA_NAMESPACE):$(SA_NAME)"}}}]}' \
	|| echo "Role already exists"; \
	echo "=== Step 3: Attach policy to role ==="; \
	aws iam attach-role-policy --role-name $(ROLE_NAME) --policy-arn $$policy_arn || echo "Policy already attached"

.PHONY: install-webhook
install-webhook:
	helm repo add jetstack https://charts.jetstack.io
	helm repo update
	helm install \
		cert-manager jetstack/cert-manager \
		--namespace cert-manager \
		--create-namespace \
		--version v1.9.1 \
		--set installCRDs=true

	helm repo add jkroepke https://jkroepke.github.io/helm-charts/
	helm repo update
	helm install amazon-eks-pod-identity-webhook \
		jkroepke/amazon-eks-pod-identity-webhook \
		-n amazon-eks-pod-identity-webhook \
		-f values.yaml \
		--create-namespace
	@kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=amazon-eks-pod-identity-webhook -n amazon-eks-pod-identity-webhook --timeout=180s
	# Sleep some extra
	@sleep 5 

	# Template out the manifest and deploy test pod
	export AWS_ACCOUNT=$(AWS_ACCOUNT) && \
	export SA_NAMESPACE=$(SA_NAMESPACE) && \
	export SA_NAME=$(SA_NAME) && \
	export ROLE_NAME=$(ROLE_NAME) && \
	envsubst < ./manifests/test-oidc.yaml > /tmp/test-oidc.yaml
	kubectl apply -f /tmp/test-oidc.yaml

	@kubectl wait --for=condition=Ready pod/aws-cli -n default --timeout=180s
	@sleep 5	
	@echo "✅ AWS CLI pod is ready!"
	kubectl exec -n default aws-cli -- aws sts get-caller-identity