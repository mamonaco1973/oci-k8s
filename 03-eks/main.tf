
provider "aws" {
  region = "us-east-2" # Default region set to US East (Ohio). Modify if your deployment requires another region.
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Fetch the most recent Ubuntu AMI provided by Canonical
# This ensures that the latest security patches and features are included

data "aws_ami" "ubuntu_ami" {
  most_recent = true                         # Get the latest available AMI
  owners      = ["099720109477"]             # Canonical's AWS Account ID for official Ubuntu images

  filter {
    name   = "name"                          # Filter AMIs by name pattern
    values = ["*ubuntu-noble-24.04-amd64-*"] # Match Ubuntu 24.04 LTS AMI for x86_64 architecture
  }
}
