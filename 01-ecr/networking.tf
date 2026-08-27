# Define a Virtual Private Cloud (VPC)
resource "aws_vpc" "k8s-vpc" {
  cidr_block           = "10.0.0.0/24"               # Define the IP address range for the VPC (256 addresses)
  enable_dns_support   = true                        # Enable DNS resolution within the VPC
  enable_dns_hostnames = true                        # Allow instances to have public DNS hostnames
  
  tags = {
    Name = "k8s-vpc"                                  # Assign a name tag for identification
  }
}

# Create an Internet Gateway (IGW) to allow outbound internet access
resource "aws_internet_gateway" "k8s-igw" {
  vpc_id = aws_vpc.k8s-vpc.id                         # Associate the IGW with the VPC
  
  tags = {
    Name = "k8s-igw"                                  # Assign a name tag for identification
  }
}

# Define a route table for managing routing rules
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.k8s-vpc.id                         # Associate the route table with the VPC
  
  tags = {
    Name = "public-route-table"                      # Assign a name tag for identification
  }
}

# Create a default route in the public route table to send all traffic to the Internet Gateway
resource "aws_route" "default_route" {
  route_table_id         = aws_route_table.public.id # Reference the public route table
  destination_cidr_block = "0.0.0.0/0"               # Define the default route (all IPs allowed)
  gateway_id             = aws_internet_gateway.k8s-igw.id 
                                                     # Use the Internet Gateway for outbound traffic
}

# Define the first public subnet within the VPC
resource "aws_subnet" "k8s-subnet-1" {
  vpc_id                  = aws_vpc.k8s-vpc.id       # Associate the subnet with the VPC
  cidr_block              = "10.0.0.0/26"            # Assign a CIDR block (64 IPs)
  map_public_ip_on_launch = true                     # Automatically assign public IPs to instances
  availability_zone       = "us-east-2a"             # Specify the availability zone
  
  tags = {
    Name = "k8s-subnet-1"                            # Assign a name tag for identification
    "kubernetes.io/role/elb" = "1"                   # Tag for public ALB
  }
}

# Define the second public subnet within the VPC
resource "aws_subnet" "k8s-subnet-2" {
  vpc_id                  = aws_vpc.k8s-vpc.id        # Associate the subnet with the VPC
  cidr_block              = "10.0.0.64/26"            # Assign a CIDR block (64 IPs, next available range)
  map_public_ip_on_launch = true                      # Automatically assign public IPs to instances
  availability_zone       = "us-east-2b"              # Specify a different availability zone for redundancy
  
  tags = {
    Name = "k8s-subnet-2"                             # Assign a name tag for identification
    "kubernetes.io/role/elb" = "1"                    # Tag for public ALBs
  }
}

# Associate the public route table with the first public subnet
resource "aws_route_table_association" "public_rta_1" {
  subnet_id      = aws_subnet.k8s-subnet-1.id         # Reference the first public subnet
  route_table_id = aws_route_table.public.id          # Attach the public route table
}

# Associate the public route table with the second public subnet
resource "aws_route_table_association" "public_rta_2" {
  subnet_id      = aws_subnet.k8s-subnet-2.id         # Reference the second public subnet
  route_table_id = aws_route_table.public.id          # Attach the public route table
}
