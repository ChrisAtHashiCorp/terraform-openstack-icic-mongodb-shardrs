resource "random_id" "cluster_id" {
  byte_length = 8
}

resource "random_id" "node_id" {
  count       = var.node_count
  byte_length = 8
}

locals {
  fqdns = [for i in range(var.node_count) : "${var.name_prefix}-${random_id.node_id[i].hex}.${var.domain}"]

  mongod-config = [for i in range(var.node_count) : templatefile("${path.module}/provision/mongod.conf.tftpl",
    {
      fqdn       = local.fqdns[i]
      cluster_id = random_id.cluster_id.hex
    }
  )]

  replicaset-config = templatefile("${path.module}/provision/replicaset-cfg.js.tftpl",
    {
      cluster_id = random_id.cluster_id.hex
      nodes      = { for k in range(var.node_count) : k => local.fqdns[k] }
    }
  )

  hostsfile = [ for i in range(var.node_count) : "${openstack_networking_port_v2.port[i].all_fixed_ips[0]} ${local.fqdns[i]}" ]

  user-data = [for i in range(var.node_count) : templatefile("${path.module}/provision/cloud-init.yml.tftpl",
    {
      fqdn              = local.fqdns[i]
      hostsfile         = base64encode(join("\n", local.hostsfile))
      mongod-config     = base64encode(local.mongod-config[i])
      replicaset-config = base64encode(local.replicaset-config)
    }
  )]
}

resource "openstack_compute_keypair_v2" "sshkey" {
  name = "${var.sshkey_prefix}-${random_id.cluster_id.hex}"
}

data "openstack_networking_network_v2" "network" {
  name = var.network
}

resource "openstack_networking_port_v2" "port" {
  count = var.node_count

  name  = "port-${random_id.cluster_id.hex}-${count.index}"
  network_id = data.openstack_networking_network_v2.network.id
}

resource "openstack_compute_instance_v2" "nodes" {
  count = var.node_count

  name        = local.fqdns[count.index]
  image_id    = var.image_id
  flavor_name = var.flavor
  key_pair    = openstack_compute_keypair_v2.sshkey.name
  user_data   = local.user-data[count.index]

  network {
    port = openstack_networking_port_v2.port[count.index].id
  }

  tags = ["cluster_id=${random_id.cluster_id.hex}", "managed=terraform"]

  lifecycle {
    ignore_changes = [user_data]
  }
}

# Create Replica Set

resource "ssh_resource" "init-replicaset" {
  bastion_host     = var.ssh_bastion.host
  bastion_user     = var.ssh_bastion.user
  bastion_password = var.ssh_bastion.password

  host     = openstack_compute_instance_v2.nodes[0].access_ip_v4
  user     = var.ssh_conn.user
  password = var.ssh_conn.password

  timeout = "30s"

  commands = ["mongosh --port 37019 /tmp/replicaset-cfg.js"]
}

# Add Shard to Cluster

resource "ssh_resource" "add-replicaset" {
  bastion_host     = var.ssh_bastion.host
  bastion_user     = var.ssh_bastion.user
  bastion_password = var.ssh_bastion.password

  host     = var.router_host
  user     = var.ssh_conn.user
  password = var.ssh_conn.password

  timeout = "30s"

  commands = [ "ls" ]
}
