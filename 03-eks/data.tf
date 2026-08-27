# -----------------------------------------------------------------------------
# DATA BLOCK: AWS VPC
# -----------------------------------------------------------------------------
# Retrieves information about an existing AWS VPC using a tag filter.
# The VPC must already exist in the AWS account and region targeted by Terraform.
# This is useful for referencing the VPC in other resources without hardcoding its ID.
data "aws_vpc" "k8s-vpc" {
  # FILTER: Define the criteria for selecting the VPC.
  filter {
    name = "tag:Name"          # Use the "Name" tag to identify the VPC.
    values = ["k8s-vpc"]       # Match the tag value for the desired VPC.
  }
}

# -----------------------------------------------------------------------------
# DATA BLOCK: AWS SUBNET 1
# -----------------------------------------------------------------------------
# Retrieves information about a specific subnet in the VPC, identified by its "Name" tag.
# This is typically used to associate resources like EC2 instances or load balancers
# with a particular subnet.
data "aws_subnet" "k8s-subnet-1" {
  # FILTER: Criteria for selecting the subnet.
  filter {
    name = "tag:Name"                  # Use the "Name" tag to identify the subnet.
    values = ["k8s-subnet-1"]          # Match the tag value for the desired subnet.
  }
}

# -----------------------------------------------------------------------------
# DATA BLOCK: AWS SUBNET 2
# -----------------------------------------------------------------------------
# Retrieves information about another specific subnet in the VPC, also identified by its "Name" tag.
# This is often used for multi-AZ deployments, associating resources with different availability zones.
data "aws_subnet" "k8s-subnet-2" {
  # FILTER: Define the criteria for selecting the subnet.
  filter {
    name = "tag:Name"                  # Use the "Name" tag to identify the subnet.
    values = ["k8s-subnet-2"]          # Match the tag value for the desired subnet.
  }
}

# -----------------------------------------------------------------------------
# DATA BLOCK: AWS PRIVATE SUBNET 1
# -----------------------------------------------------------------------------
# Retrieves information about the first private subnet in the VPC, identified by its "Name" tag.
# This enables referencing the subnet dynamically without hardcoding its ID.
data "aws_subnet" "k8s-private-subnet-1" {
  # FILTER: Criteria for selecting the subnet.
  filter {
    name   = "tag:Name"                     # Use the "Name" tag to identify the subnet.
    values = ["k8s-private-subnet-1"]       # Match the tag value for the desired private subnet.
  }
}

# -----------------------------------------------------------------------------
# DATA BLOCK: AWS PRIVATE SUBNET 2
# -----------------------------------------------------------------------------
# Retrieves information about the second private subnet in the VPC, also identified by its "Name" tag.
# Useful for multi-AZ or high availability deployments that span private subnets.
data "aws_subnet" "k8s-private-subnet-2" {
  # FILTER: Define the criteria for selecting the subnet.
  filter {
    name   = "tag:Name"                     # Use the "Name" tag to identify the subnet.
    values = ["k8s-private-subnet-2"]       # Match the tag value for the desired private subnet.
  }
}
