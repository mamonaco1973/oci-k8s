# Allocate an Elastic IP for the NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "nat-eip"
  }
}

# Create the NAT Gateway in one of the public subnets
resource "aws_nat_gateway" "k8s-nat-gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.k8s-subnet-1.id  # Place NAT GW in public subnet 1
  tags = {
    Name = "k8s-nat-gw"
  }

  depends_on = [aws_internet_gateway.k8s-igw]
}

# Create a private route table for private subnets
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.k8s-vpc.id

  tags = {
    Name = "private-route-table"
  }
}

# Create a default route in the private route table that uses the NAT Gateway
resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.k8s-nat-gw.id
}

# Define the first private subnet
resource "aws_subnet" "k8s-private-subnet-1" {
  vpc_id            = aws_vpc.k8s-vpc.id
  cidr_block        = "10.0.0.128/26"               # Next available /26 block
  availability_zone = "us-east-2a"

  tags = {
    Name = "k8s-private-subnet-1"
    "kubernetes.io/role/internal-elb" = "1"         # Used for internal load balancers
  }
}

# Define the second private subnet
resource "aws_subnet" "k8s-private-subnet-2" {
  vpc_id            = aws_vpc.k8s-vpc.id
  cidr_block        = "10.0.0.192/26"               # Next available /26 block
  availability_zone = "us-east-2b"

  tags = {
    Name = "k8s-private-subnet-2"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Associate private route table with private subnet 1
resource "aws_route_table_association" "private_rta_1" {
  subnet_id      = aws_subnet.k8s-private-subnet-1.id
  route_table_id = aws_route_table.private.id
}

# Associate private route table with private subnet 2
resource "aws_route_table_association" "private_rta_2" {
  subnet_id      = aws_subnet.k8s-private-subnet-2.id
  route_table_id = aws_route_table.private.id
}
