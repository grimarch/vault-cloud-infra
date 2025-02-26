disable_mlock = true
ui            = true
api_addr      = "https://10.1.42.105:8200"
cluster_addr  = "https://10.1.42.105:8201"

listener "tcp" {
  address            = "0.0.0.0:8200"
  tls_cert_file      = "/vault/certs/server_cert.pem"
  tls_key_file       = "/vault/certs/server_key.pem"
  tls_client_ca_file = "/vault/certs/vault_docker_lab_ca.pem"
  tls_disable        = "false"
}

storage "raft" {
  path    = "/vault"
  node_id = "vault-docker-lab-5"

    retry_join {
    leader_tls_servername   = "vault-docker-lab1.vault-docker-lab.lan"
    leader_api_addr         = "https://10.1.42.101:8200"
    leader_ca_cert_file     = "/vault/certs/vault_docker_lab_ca.pem"
    leader_client_cert_file = "/vault/certs/server_cert.pem"
    leader_client_key_file  = "/vault/certs/server_key.pem"
  }

}
