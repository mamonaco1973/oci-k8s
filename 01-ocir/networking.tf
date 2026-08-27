# ==============================================================================
# FILE: networking.tf — VCN baseline for the OKE cluster
# ------------------------------------------------------------------------------
# THREE SUBNETS, NOT FOUR.
#
# The AWS original ran two public and two private subnets, one pair per
# availability zone, because AWS subnets are zonal and an ALB needs a subnet in
# at least two of them. OCI subnets are REGIONAL — a single subnet already
# spans every availability domain in the region, and the load balancer places
# itself across them on its own. The AZ pairing has nothing to do here, so the
# four subnets collapse to three, split by ROLE rather than by zone:
#
#   k8s-api-subnet   public   the Kubernetes API endpoint
#   k8s-lb-subnet    public   service load balancers
#   k8s-node-subnet  private  worker nodes
#
# OKE wants these separated because each one carries a different security list.
# ==============================================================================

# ==============================================================================
# SECTION: VCN — one /24, same address space the AWS build used
# ==============================================================================

resource "oci_core_vcn" "k8s_vcn" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/24"
  display_name   = "k8s-vcn"

  # dns_label must be alphanumeric and 15 characters or fewer.
  dns_label = "k8svcn"
}

# ==============================================================================
# SECTION: Gateways
# ------------------------------------------------------------------------------
# Three, each with a distinct job:
#   internet gateway  inbound to the public subnets, outbound for the endpoint
#   NAT gateway       outbound for the private node subnet (helm charts, apt)
#   service gateway   OCIR and Object Storage over the OCI backbone, not the
#                     internet — image pulls skip the NAT and its data charges
# ==============================================================================

resource "oci_core_internet_gateway" "k8s_igw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "k8s-igw"
  enabled        = true
}

resource "oci_core_nat_gateway" "k8s_nat" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "k8s-nat"
}

# The "all services" CIDR label is region-specific and must be looked up.
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "k8s_sgw" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "k8s-sgw"

  services {
    service_id = data.oci_core_services.all_services.services[0].id
  }
}

# ==============================================================================
# SECTION: Route Tables
# ==============================================================================

resource "oci_core_route_table" "public_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "public-route-table"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.k8s_igw.id
  }
}

resource "oci_core_route_table" "private_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "private-route-table"

  # General egress for the nodes — chart downloads, package installs.
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.k8s_nat.id
  }

  # OCI service traffic takes the backbone instead. More specific than the
  # default route, so it wins for OCIR and Object Storage.
  route_rules {
    destination       = data.oci_core_services.all_services.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.k8s_sgw.id
  }
}

# ==============================================================================
# SECTION: Security List — API endpoint subnet
# ------------------------------------------------------------------------------
# 6443 is the Kubernetes API itself. 12250 is the OKE-specific control plane
# port the kubelet uses to reach the managed control plane; leaving it out
# produces nodes that join and then go NotReady with no obvious cause.
# ==============================================================================

resource "oci_core_security_list" "api_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "k8s-api-security-list"

  # kubectl from anywhere — this is a lab cluster with a public endpoint.
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.node_cidr
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = local.node_cidr
    tcp_options {
      min = 12250
      max = 12250
    }
  }

  # Path MTU discovery. Without it, large API responses stall instead of
  # failing, which is far harder to diagnose than a refused connection.
  ingress_security_rules {
    protocol = "1"
    source   = local.node_cidr
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# ==============================================================================
# SECTION: Security List — worker node subnet
# ------------------------------------------------------------------------------
# Wide open within the subnet because flannel carries pod-to-pod traffic
# between nodes and the pod addresses are not visible to the security list.
# ==============================================================================

resource "oci_core_security_list" "node_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "k8s-node-security-list"

  # Node-to-node, including the flannel overlay.
  ingress_security_rules {
    protocol = "all"
    source   = local.node_cidr
  }

  # Control plane to kubelet — exec, logs, port-forward and probes.
  ingress_security_rules {
    protocol = "all"
    source   = local.api_cidr
  }

  # Load balancer to NodePort. The OCI load balancer created by the cloud
  # controller manager targets nodes on a port from this range.
  ingress_security_rules {
    protocol = "6"
    source   = local.lb_cidr
    tcp_options {
      min = 30000
      max = 32767
    }
  }

  # Health checks arrive on the same range as the traffic.
  ingress_security_rules {
    protocol = "6"
    source   = local.lb_cidr
    tcp_options {
      min = 10256
      max = 10256
    }
  }

  ingress_security_rules {
    protocol = "1"
    source   = "0.0.0.0/0"
    icmp_options {
      type = 3
      code = 4
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# ==============================================================================
# SECTION: Security List — load balancer subnet
# ==============================================================================

resource "oci_core_security_list" "lb_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.k8s_vcn.id
  display_name   = "k8s-lb-security-list"

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# ==============================================================================
# SECTION: Subnets
# ------------------------------------------------------------------------------
# k8s-api-subnet   10.0.0.0/28     public   Kubernetes API endpoint
# k8s-lb-subnet    10.0.0.16/28    public   service load balancers
# k8s-node-subnet  10.0.0.128/25   private  worker nodes
#
# The node subnet is the large one because it holds every worker. Pods do not
# consume subnet addresses here — the cluster uses the flannel overlay, so pod
# IPs come from a private range that never touches the VCN.
# ==============================================================================

locals {
  api_cidr  = "10.0.0.0/28"
  lb_cidr   = "10.0.0.16/28"
  node_cidr = "10.0.0.128/25"
}

resource "oci_core_subnet" "k8s_api_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.k8s_vcn.id
  cidr_block                 = local.api_cidr
  display_name               = "k8s-api-subnet"
  dns_label                  = "k8sapi"
  route_table_id             = oci_core_route_table.public_rt.id
  security_list_ids          = [oci_core_security_list.api_sl.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "k8s_lb_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.k8s_vcn.id
  cidr_block                 = local.lb_cidr
  display_name               = "k8s-lb-subnet"
  dns_label                  = "k8slb"
  route_table_id             = oci_core_route_table.public_rt.id
  security_list_ids          = [oci_core_security_list.lb_sl.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "k8s_node_subnet" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.k8s_vcn.id
  cidr_block                 = local.node_cidr
  display_name               = "k8s-node-subnet"
  dns_label                  = "k8snode"
  route_table_id             = oci_core_route_table.private_rt.id
  security_list_ids          = [oci_core_security_list.node_sl.id]
  prohibit_public_ip_on_vnic = true
}
