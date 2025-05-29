# This Makefile is based on learn-vault-docker-lab by HashiCorp Education.
# Modified by Denis Zwinger in 2025 to support cloud deployment, cloud-init,
# logging, and multi-stage Terraform execution.
# Licensed under the Mozilla Public License 2.0.

# ------------------------------------------------------------------------------
# Vault Cloud Infra — Makefile
# ------------------------------------------------------------------------------
# Provides automation for:
# - Terraform initialization and apply
# - cloud-init provisioning of VMs
# - Vault bootstrap and audit logging
# ------------------------------------------------------------------------------


MY_NAME_IS := [vault-docker-lab]
THIS_FILE := $(lastword $(MAKEFILE_LIST))
UNAME := $$(uname)
VAULT_DOCKER_LAB_AUDIT_LOGS = ./containers/vault_docker_lab_?/logs/*
VAULT_DOCKER_LAB_DATA = ./containers/vault_docker_lab_?/data/*
VAULT_DOCKER_LAB_INIT = ./.vault_docker_lab_?_init
VAULT_DOCKER_LAB_LOG_FILE = ./vault_docker_lab.log

default: all

all: prerequisites provision vault_status unseal_nodes audit_device done bootstrap

stage: prerequisites provision done-stage

done:
	@echo "$(MY_NAME_IS) Export VAULT_ADDR for the active node: export VAULT_ADDR=https://127.0.0.1:8200"
	@echo "$(MY_NAME_IS) Login to Vault with initial root token: vault login $$(grep 'Initial Root Token' ./.vault_docker_lab_1_init | awk '{print $$NF}')"

done-stage:
	@echo "$(MY_NAME_IS) Export VAULT_ADDR for the active node: export VAULT_ADDR=https://127.0.0.1:8200"
	@echo "$(MY_NAME_IS) Vault is not initialized or unsealed. You must initialize and unseal Vault prior to use."

DOCKER_OK=$$(docker info > /dev/null 2>&1; printf $$?)
TERRAFORM_BINARY_OK=$$(which terraform > /dev/null 2>&1 ; printf $$?)
VAULT_BINARY_OK=$$(which vault > /dev/null 2>&1 ; printf $$?)
prerequisites:
	@if [ $(VAULT_BINARY_OK) -ne 0 ] ; then echo "$(MY_NAME_IS) Vault binary not found in path!"; echo "$(MY_NAME_IS) Install Vault and try again: https://developer.hashicorp.com/vault/downloads." ; exit 1 ; fi
	@if [ $(TERRAFORM_BINARY_OK) -ne 0 ] ; then echo "$(MY_NAME_IS) Terraform CLI binary not found in path!" ; echo "$(MY_NAME_IS) Install Terraform CLI and try again: https://developer.hashicorp.com/terraform/downloads" ; exit 1 ; fi
	@if [ $(DOCKER_OK) -ne 0 ] ; then echo "$(MY_NAME_IS) Cannot get Docker info; ensure that Docker is running, and try again." ; exit 1 ; fi

provision:
	@if [ "$(UNAME)" = "Linux" ]; then echo "$(MY_NAME_IS) [Linux] Setting ownership on container volume directories ..."; echo "$(MY_NAME_IS) [Linux] You could be prompted for your user password by sudo."; sudo chown -R $$USER:$$USER containers; sudo chmod -R 0777 containers; fi
	@printf "$(MY_NAME_IS) Initializing Terraform workspace ..."
	@terraform init > $(VAULT_DOCKER_LAB_LOG_FILE)
	@echo 'Done.'
	@printf "$(MY_NAME_IS) Applying Terraform configuration ..."
	@terraform apply -auto-approve >> $(VAULT_DOCKER_LAB_LOG_FILE)
	@echo 'Done.'

UNSEAL_KEY=$$(grep 'Unseal Key 1' ./.vault_docker_lab_1_init | awk '{print $$NF}')
unseal_nodes:
	@printf "$(MY_NAME_IS) Unsealing cluster nodes ..."
	@until [ $$(VAULT_ADDR=https://127.0.0.1:8220 vault status | grep "Initialized" | awk '{print $$2}') = "true" ] ; do sleep 1 ; printf . ; done
	@VAULT_ADDR=https://127.0.0.1:8220 vault operator unseal $(UNSEAL_KEY) >> $(VAULT_DOCKER_LAB_LOG_FILE)
	@printf 'node 2. '
	@until [ $$(VAULT_ADDR=https://127.0.0.1:8230 vault status | grep "Initialized" | awk '{print $$2}') = "true" ] ; do sleep 1 ; printf . ; done
	@VAULT_ADDR=https://127.0.0.1:8230 vault operator unseal $(UNSEAL_KEY) >> $(VAULT_DOCKER_LAB_LOG_FILE)
	@printf 'node 3. '
	@until [ $$(VAULT_ADDR=https://127.0.0.1:8240 vault status | grep "Initialized" | awk '{print $$2}') = "true" ] ; do sleep 1 ; printf . ; done
	@VAULT_ADDR=https://127.0.0.1:8240 vault operator unseal $(UNSEAL_KEY) >> $(VAULT_DOCKER_LAB_LOG_FILE)
	@printf 'node 4. '
	@until [ $$(VAULT_ADDR=https://127.0.0.1:8250 vault status | grep "Initialized" | awk '{print $$2}') = "true" ] ; do sleep 1 ; printf . ; done
	@VAULT_ADDR=https://127.0.0.1:8250 vault operator unseal $(UNSEAL_KEY) >> $(VAULT_DOCKER_LAB_LOG_FILE)
	@printf 'node 5. '
	@echo 'Done.'

ROOT_TOKEN=$$(grep 'Initial Root Token' ./.vault_docker_lab_1_init | awk '{print $$NF}')
audit_device:
	@printf "$(MY_NAME_IS) Enable audit device ..."
	@VAULT_ADDR=https://127.0.0.1:8220 VAULT_TOKEN=$(ROOT_TOKEN) vault audit enable file file_path=/vault/logs/vault_audit.log > /dev/null 2>&1
	@echo 'Done.'

vault_status:
	@printf "$(MY_NAME_IS) Checking Vault active node status ..."
	@until [ $$(VAULT_ADDR=https://127.0.0.1:8200 vault status > /dev/null 2>&1 ; printf $$?) -eq 0 ] ; do sleep 1 && printf . ; done
	@echo 'Done.'
	@printf "$(MY_NAME_IS) Checking Vault initialization status ..."
	@until [ $$(VAULT_ADDR=https://127.0.0.1:8200 vault status | grep "Initialized" | awk '{print $$2}') = "true" ] ; do sleep 1 ; printf . ; done
	@echo 'Done.'

clean:
	@if [ "$(UNAME)" = "Linux" ]; then echo "$(MY_NAME_IS) [Linux] Setting ownership on container volume directories ..."; echo "$(MY_NAME_IS) [Linux] You could be prompted for your user password by sudo."; sudo chown -R $$USER:$$USER containers; fi
	@printf "$(MY_NAME_IS) Destroying Terraform configuration ..."
	@terraform destroy -auto-approve >> $(VAULT_DOCKER_LAB_LOG_FILE)
	@echo 'Done.'
	@printf "$(MY_NAME_IS) Removing artifacts created by vault-docker-lab ..."
	@rm -rf $(VAULT_DOCKER_LAB_DATA)
	@rm -f $(VAULT_DOCKER_LAB_INIT)
	@rm -rf $(VAULT_DOCKER_LAB_AUDIT_LOGS)
	@rm -f $(VAULT_DOCKER_LAB_LOG_FILE)
	@echo 'Done.'

cleanest: clean
	@printf "$(MY_NAME_IS) Removing all Terraform runtime configuration and state ..."
	@rm -fv terraform.tfstate
	@rm -fv terraform.tfstate.backup
	@rm -rfv .terraform
	@rm -fv .terraform.lock.hcl
	@make remove-bootstrap
	@echo 'Done.'

bootstrap:
	@echo "$(MY_NAME_IS) Run init-bootstrap.sh (initial bootstrap Vault)..."
	@./scripts/init-bootstrap.sh 
	@echo "$(MY_NAME_IS) Bootstrap completed successfully."

remove-bootstrap:
	@echo "$(MY_NAME_IS) Removing bootstrap artifacts..."
	@rm -fv .vault_bootstrap_done
	@echo "$(MY_NAME_IS) Bootstrap artifacts removed successfully."

check-do-token:
	@if [ -z "$(TF_VAR_do_token)" ]; then \
		echo "❌ Error: TF_VAR_do_token environment variable is not set!"; \
		echo "📝 Please set your DigitalOcean API token:"; \
		echo "   export TF_VAR_do_token=\"your_digitalocean_api_token\""; \
		exit 1; \
	fi

MY_NAME_IS := [vault-cloud-infra]
deploy: check-do-token
	@echo "$(MY_NAME_IS) Running deploy script..."
	@./scripts/deploy.sh
	@echo "$(MY_NAME_IS) Deploy script completed successfully."

deploy-debug: check-do-token
	@echo "$(MY_NAME_IS) Running deploy script in debug mode..."
	@./scripts/deploy.sh --debug
	@echo "$(MY_NAME_IS) Deploy script completed successfully."

destroy: check-do-token
	@echo "$(MY_NAME_IS) Running destroy script..."
	@terraform destroy -auto-approve
	@read -p "⚠️  This will remove all Terraform configuration on your local machine. Are you sure you want to clean up Terraform configuration? (y/n): " confirm; \
	if [ "$$confirm" != "y" ]; then \
		echo "🚫 Cleanup cancelled"; \
		exit 1; \
	fi;
	@echo "$(MY_NAME_IS) Removing Terraform configuration..."
	@rm -rfv .terraform \
        terraform.tfstate \
        terraform.tfstate.backup \
        .terraform.lock.hcl \
        .vault_docker_lab_1_init \
		.bootstrap-token \
        stage1.tfplan \
        stage2.tfplan
	@echo "$(MY_NAME_IS) Destroy script completed successfully."

revoke-root-token:
	@echo "$(MY_NAME_IS) Revoking root token..."
	@VAULT_ADDR=https://127.0.0.1:8200 VAULT_TOKEN=$(ROOT_TOKEN) vault token revoke $(ROOT_TOKEN)
	@echo "$(MY_NAME_IS) Root token revoked successfully."


archive-logs:
	@echo "📦 Archiving logs..."
	@timestamp=$$(date +%Y%m%d_%H%M%S); \
	archive_name="logs/deploy-$${timestamp}.tar.zst"; \
	find logs/ -type f -name '*.log' > logs_to_archive.txt; \
	tar --files-from=logs_to_archive.txt -I 'zstd -19 -T0' -cf "$${archive_name}"; \
	echo "🗑️  Deleting archived files..."; \
	xargs rm -v < logs_to_archive.txt; \
	rm logs_to_archive.txt; \
	echo "✅ Archive created: $${archive_name}"


.PHONY: all
