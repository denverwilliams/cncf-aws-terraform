SHELL += -eu

BLUE := \033[0;34m
GREEN := \033[0;32m
RED := \033[0;31m
NC := \033[0m


# ∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨∨

AWS_REGION := ${aws_region:-us-east-1}
COREOS_CHANNEL := ${coreos_channel:-stable}
COREOS_VM_TYPE := ${coreos_vm_type:-hvm}

CLUSTER_NAME := ${cluster_name:-test}
AWS_EC2_KEY_NAME := ${aws_ec2_key_name:-kz8s-test}

INTERNAL_TLD := ${internal_tld:-test.kz8s}

# CIDR_PODS: flannel overlay range
# - https://coreos.com/flannel/docs/latest/flannel-config.html
#
# CIDR_SERVICE_CLUSTER: apiserver parameter --service-cluster-ip-range
# - http://kubernetes.io/docs/admin/kube-apiserver/
#
# CIDR_VPC: vpc subnet
# - http://docs.aws.amazon.com/AmazonVPC/latest/UserGuide/VPC_Subnets.html#VPC_Sizing
# - https://www.terraform.io/docs/providers/aws/r/vpc.html#cidr_block
#
CIDR_PODS := ${cidr_pods:-10.2.0.0/16}
CIDR_SERVICE_CLUSTER := ${cidr_service_cluster:-10.3.0.0/24}
K8S_SERVICE_IP := ${k8s_service_ip:-10.3.0.1}
K8S_DNS_IP := ${k8s_dns_ip:-10.3.0.10}

CIDR_VPC := ${cidr_vpc:-10.0.0.0/16}
ETCD_IPS := ${etcd_ips:-10.0.10.10,10.0.10.11,10.0.10.12}

HYPERKUBE_IMAGE ?= ${hyperkube_image:-quay.io/coreos/hyperkube}
HYPERKUBE_TAG ?= ${hyperkube_tag:-v1.4.7_coreos.0}

# Alternative:
# CIDR_PODS ?= "172.15.0.0/16"
# CIDR_SERVICE_CLUSTER ?= "172.16.0.0/24"
# K8S_SERVICE_IP ?= 172.16.0.1
# K8S_DNS_IP ?= 172.16.0.10

# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


DIR_KEY_PAIR := /root/.aws/keypair
DIR_SSL := .cfssl

.addons:
	@echo "${BLUE}❤ initialize add-ons ${NC}"
	@./scripts/init-addons
	@echo "${GREEN}✓ initialize add-ons - success ${NC}\n"

## generate key-pair, variables and then `terraform apply`
all: prereqs create-keypair ssl init apply
	@echo "${GREEN}✓ terraform portion of 'make all' has completed ${NC}\n"
	@$(MAKE) wait-for-cluster
	@$(MAKE) .addons
	@$(MAKE) create-addons
	@$(MAKE) create-busybox
	kubectl get no
	@echo "${BLUE}❤ worker nodes may take several minutes to come online ${NC}"
	@$(MAKE) instances
	@echo "View nodes:"
	@echo "% make nodes"
	@echo "---"
	@echo "View uninitialized kube-system pods:"
	@echo "% make pods"
	@echo "---"
	@echo "View ec2 instance info:"
	@echo "% make instances"
	@echo "---"
	@echo "Status summaries:"
	@echo "% make status"

.cfssl: ; ./scripts/init-cfssl ${DIR_SSL} ${AWS_REGION} ${INTERNAL_TLD} ${K8S_SERVICE_IP}

## destroy and remove everything
clean: destroy delete-keypair
	@-pkill -f "kubectl proxy" ||:
	@-rm -rf .addons ||:
	@-rm terraform.tfvars ||:
	@-rm terraform.tfplan ||:
	@-rm -rf .terraform ||:
	@-rm -rf tmp ||:
	@-rm -rf ${DIR_SSL} ||:

create-addons:
	@echo "${BLUE}❤ create add-ons ${NC}"
	kubectl create -f .addons/ --recursive
	@echo "${GREEN}✓ create add-ons - success ${NC}\n"

create-busybox:
	@echo "${BLUE}❤ create busybox test pod ${NC}"
	kubectl create -f test/pods/busybox.yml
	@echo "${GREEN}✓ create busybox test pod - success ${NC}\n"

## start proxy and open kubernetes dashboard
dashboard: ; @./scripts/dashboard

## show instance information
instances:
	@scripts/instances `terraform output -state /home/terraform/data/terraform.state name` `terraform output -state /home/terraform/data/terraform.state region`

## journalctl on etcd1
journal:
	@scripts/ssh ${DIR_KEY_PAIR}/${AWS_EC2_KEY_NAME}.pem `terraform output -state /home/terraform/data/terraform.state bastion-ip` "ssh `terraform output -state /home/terraform/data/terraform.state etcd1-ip` journalctl -fl"

prereqs:
	aws --version
	@echo
	cfssl version
	@echo
	jq --version
	@echo
	kubectl version --client
	@echo
	terraform --version

## ssh into etcd1
ssh:
	@scripts/ssh ${DIR_KEY_PAIR}/${AWS_EC2_KEY_NAME}.pem `terraform output -state /home/terraform/data/terraform.state bastion-ip` "ssh `terraform output -state /home/terraform/data/terraform.state etcd1-ip`"

## ssh into bastion host
ssh-bastion:
	@scripts/ssh ${DIR_KEY_PAIR}/${AWS_EC2_KEY_NAME}.pem `terraform output -state /home/terraform/data/terraform.state bastion-ip`

## status
status: instances
	kubectl get no
	kubectl cluster-info
	kubectl get po --namespace=kube-system
	kubectl get po
	kubectl exec busybox -- nslookup kubernetes

## create tls artifacts
ssl: .cfssl

## smoke it
test: test-ssl test-route53 test-etcd pods dns

wait-for-cluster:
	@echo "${BLUE}❤ wait-for-cluster ${NC}"
	@scripts/wait-for-cluster
	@echo "${GREEN}✓ wait-for-cluster - success ${NC}\n"

include makefiles/*.mk

.DEFAULT_GOAL := help
.PHONY: all clean create-addons create-busybox instances journal prereqs ssh ssh-bastion ssl status test wait-for-cluster
