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
deploy: check-do-token check-ssh-vars check-public-ip check-emergency-enabled
	@echo "$(MY_NAME_IS) Running deploy script..."
	@./scripts/deploy.sh
	@echo "$(MY_NAME_IS) Deploy script completed successfully."

deploy-debug: check-do-token check-ssh-vars check-public-ip check-emergency-enabled
	@echo "$(MY_NAME_IS) Running deploy script in debug mode..."
	@echo "$(MY_NAME_IS) Note: SSH path and port settings will be taken from terraform.tfvars"
	@./scripts/deploy.sh --debug
	@echo "$(MY_NAME_IS) Deploy script completed successfully."

destroy: check-do-token check-public-ip
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

check-ssh-vars:
	@missing_vars=""; \
	for var in do_ssh_key_fingerprint ssh_private_key_path allowed_ssh_cidr_blocks; do \
	  env_val=$$(printenv $${var} || true); \
	  tfvars_val=$$(grep -E "^$${var}[[:space:]]*=" terraform.tfvars 2>/dev/null | grep -v '^#' | head -n1 | cut -d'=' -f2- | tr -d ' "\n\r\t'); \
	  if [ -z "$$env_val" ] && [ -z "$$tfvars_val" ]; then \
	    missing_vars="$$missing_vars $${var}"; \
	  fi; \
	done; \
	if [ -n "$$missing_vars" ]; then \
	  echo "❌ ERROR: The following required variables are missing in both environment and terraform.tfvars:$$missing_vars"; \
	  echo "   Please set them in terraform.tfvars or export as environment variables before proceeding."; \
	  exit 1; \
	fi

check-public-ip:
	@current_ip=$$(curl -s https://api.ipify.org); \
	tf_ips=$$(grep -E '^allowed_ssh_cidr_blocks' terraform.tfvars | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'); \
	match_found=0; \
	for ip in $$tf_ips; do \
	  if [ "$$current_ip" = "$$ip" ]; then match_found=1; fi; \
	done; \
	if [ "$$match_found" = "1" ]; then \
	  echo "✅ Your public IP ($$current_ip) is allowed."; \
	else \
	  echo "❌ Your IP ($$current_ip) is not listed in allowed_ssh_cidr_blocks! Add it to terraform.tfvars or run ./scripts/update_ssh_access.sh"; \
	  exit 1; \
	fi

emergency-ssh-on: check-do-token check-ssh-vars check-public-ip
	@read -p "Are you sure you want to enable emergency SSH access? It will allow SSH access from any IP address. (y/n): " confirm; \
	if [ "$$confirm" != "y" ]; then \
		echo "🚫 Emergency SSH access cancelled"; \
		exit 1; \
	fi
	@echo "🔓 Enabling emergency SSH access from 0.0.0.0/0..."
	@if grep -q '^emergency_ssh_access' terraform.tfvars; then \
	  sed -i 's/^emergency_ssh_access *= *.*/emergency_ssh_access = true/' terraform.tfvars; \
	else \
	  echo 'emergency_ssh_access = true' >> terraform.tfvars; \
	fi
	@terraform apply -target=digitalocean_firewall.vault_firewall -auto-approve
	@echo ""
	@echo "📌 If SSH is unavailable, use the Droplet Console:"
	@echo "👉 https://cloud.digitalocean.com/droplets → Console"
	@echo ""
	@echo "🛑 Don't forget to run: make emergency-ssh-off"

emergency-ssh-off: check-do-token check-ssh-vars check-public-ip
	@read -p "Are you sure you want to disable emergency SSH access? (y/n): " confirm; \
	if [ "$$confirm" != "y" ]; then \
		echo "🚫 Emergency SSH access disabled"; \
		exit 1; \
	fi
	@echo "🔐 Disabling emergency SSH access..."
	@if grep -q '^emergency_ssh_access' terraform.tfvars; then \
	  sed -i 's/^emergency_ssh_access *= *.*/emergency_ssh_access = false/' terraform.tfvars; \
	else \
	  echo 'emergency_ssh_access = false' >> terraform.tfvars; \
	fi
	@terraform apply -target=digitalocean_firewall.vault_firewall -auto-approve
	@echo ""
	@echo "🔒 Emergency SSH access disabled."

check-emergency-enabled:
	@value=$$(grep -E '^emergency_ssh_access *= *true' terraform.tfvars || true); \
	if [ -n "$$value" ]; then \
	  echo "🟠 emergency_ssh_access is ENABLED"; \
	  echo "⚠️  Your server will be opened to the world (0.0.0.0/0)."; \
	  echo "💡 You can disable it with: make emergency-ssh-off"; \
	  read -p "❓ Continue anyway? (y/n): " confirm; \
	  if [ "$$confirm" != "y" ]; then \
	    echo "🚫 Aborted."; \
	    exit 1; \
	  fi; \
	else \
	  echo "🟢 emergency_ssh_access is DISABLED (restricted SSH)"; \
	fi


.PHONY: all
