provider "aws" {
  region = local.region
}

locals {
  name   = "ex-tgw-${replace(basename(path.cwd), "_", "-")}"
  region = "us-east-1"

  tags = {
    Example    = local.name
    GithubRepo = "terraform-aws-eks"
    GithubOrg  = "terraform-aws-transit-gateway"
  }
}

################################################################################
# Transit Gateway Module
################################################################################

module "tgw" {
  source = "../../"

  name            = local.name
  description     = "My TGW shared with several other AWS accounts"
  amazon_side_asn = 64532

  transit_gateway_cidr_blocks = ["10.99.0.0/24"]

  # When "true" there is no need for RAM resources if using multiple AWS accounts
  enable_auto_accept_shared_attachments = true

  # When "true", allows service discovery through IGMP
  enable_mutlicast_support = false

  enable_default_route_table_association = false
  enable_default_route_table_propagation = false

  share_tgw = false

  tags = local.tags
}

################################################################################
# Supporting resources
################################################################################

module "vpc_shrd" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "shrd-vpc"
  cidr = "10.3.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.3.11.0/24", "10.3.12.0/24", "10.3.13.0/24"]
  public_subnets  = ["10.3.1.0/24", "10.3.2.0/24", "10.3.3.0/24"]

  tags = local.tags
}

resource "aws_route" "shrd_to_tgw_private" {
  count                  = length(module.vpc_shrd.azs)
  route_table_id         = module.vpc_shrd.private_route_table_ids[count.index]
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_shrd,
  ]
}

resource "aws_route" "shrd_to_tgw_public" {
  route_table_id         = module.vpc_shrd.public_route_table_ids[0]
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_shrd,
  ]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachment_shrd" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id

  # Attach VPC and private subnets to the Transit Gateway
  vpc_id     = module.vpc_shrd.vpc_id
  subnet_ids = module.vpc_shrd.public_subnets

  # Turn off default route table association and propagation, as we're providing our own
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
}

resource "aws_ec2_transit_gateway_route_table" "tgw_rt_shrd" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw_route_association_shrd" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_shrd.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_shrd.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_shrd_to_dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_shrd.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_shrd_to_qa" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_qa.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_shrd.id
}

module "vpc_dev" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "dev-vpc"
  cidr = "10.1.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]
  public_subnets  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]

  create_igw = false

  tags = local.tags
}

resource "aws_route" "dev_to_tgw_private" {
  count                  = length(module.vpc_dev.azs)
  route_table_id         = module.vpc_dev.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_dev,
  ]
}

resource "aws_route" "dev_to_tgw_public" {
  route_table_id         = module.vpc_dev.public_route_table_ids[0]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_dev,
  ]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachment_dev" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id

  # Attach VPC and private subnets to the Transit Gateway
  vpc_id     = module.vpc_dev.vpc_id
  subnet_ids = module.vpc_dev.public_subnets

  # Turn off default route table association and propagation, as we're providing our own
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
}

resource "aws_ec2_transit_gateway_route_table" "tgw_rt_dev" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw_route_association_dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_dev.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_dev_to_shrd" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_shrd.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_dev.id
}

module "vpc_qa" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "qa-vpc"
  cidr = "10.2.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.2.11.0/24", "10.2.12.0/24", "10.2.13.0/24"]
  public_subnets  = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]

  create_igw = false

  tags = local.tags
}

resource "aws_route" "qa_to_tgw_private" {
  count                  = length(module.vpc_qa.azs)
  route_table_id         = module.vpc_qa.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_qa,
  ]
}

resource "aws_route" "qa_to_tgw_public" {
  route_table_id         = module.vpc_qa.public_route_table_ids[0]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_qa,
  ]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachment_qa" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id

  # Attach VPC and private subnets to the Transit Gateway
  vpc_id     = module.vpc_qa.vpc_id
  subnet_ids = module.vpc_qa.public_subnets

  # Turn off default route table association and propagation, as we're providing our own
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
}

resource "aws_ec2_transit_gateway_route_table" "tgw_rt_qa" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw_route_association_qa" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_qa.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_qa.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_qa_to_shrd" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_shrd.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt_qa.id
}

################################################################################
# EC2 resources for testing connectivity
################################################################################

resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = var.public_key
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-hvm-*-x86_64-gp2"]
  }
}

module "security_group_shrd" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-sg-shrd"
  description = "Security group for usage with EC2 instances"
  vpc_id      = module.vpc_shrd.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["ssh-tcp"]
  egress_rules        = ["all-all"]

  tags = local.tags
}

module "ec2_shrd" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 4.0.0"

  name = "vm-shrd"

  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  availability_zone           = element(module.vpc_shrd.azs, 0)
  subnet_id                   = element(module.vpc_shrd.public_subnets, 0)
  vpc_security_group_ids      = [module.security_group_shrd.security_group_id]
  associate_public_ip_address = true

  hibernation = true

  user_data = ""

  capacity_reservation_specification = {
    capacity_reservation_preference = "open"
  }

  enable_volume_tags = false

  root_block_device = [
    {
      encrypted   = true
      volume_type = "gp2"
      volume_size = 8
    },
  ]

  key_name = aws_key_pair.deployer.key_name

  tags = local.tags
}

module "security_group_dev" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-sg-dev"
  description = "Security group for usage with EC2 instances"
  vpc_id      = module.vpc_dev.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["ssh-tcp"]
  egress_rules        = ["all-all"]

  tags = local.tags
}

module "ec2_dev" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 4.0.0"

  name = "vm-dev"

  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  availability_zone           = element(module.vpc_dev.azs, 0)
  subnet_id                   = element(module.vpc_dev.private_subnets, 0)
  vpc_security_group_ids      = [module.security_group_dev.security_group_id]
  associate_public_ip_address = false

  hibernation = true

  user_data = ""

  capacity_reservation_specification = {
    capacity_reservation_preference = "open"
  }

  enable_volume_tags = false

  root_block_device = [
    {
      encrypted   = true
      volume_type = "gp2"
      volume_size = 8
    },
  ]

  key_name = aws_key_pair.deployer.key_name

  tags = local.tags
}

module "security_group_qa" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-sg-qa"
  description = "Security group for usage with EC2 instances"
  vpc_id      = module.vpc_qa.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["ssh-tcp"]
  egress_rules        = ["all-all"]

  tags = local.tags
}

module "ec2_qa" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 4.0.0"

  name = "vm-qa"

  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  availability_zone           = element(module.vpc_qa.azs, 0)
  subnet_id                   = element(module.vpc_qa.private_subnets, 0)
  vpc_security_group_ids      = [module.security_group_qa.security_group_id]
  associate_public_ip_address = false

  hibernation = true

  user_data = ""

  capacity_reservation_specification = {
    capacity_reservation_preference = "open"
  }

  enable_volume_tags = false

  root_block_device = [
    {
      encrypted   = true
      volume_type = "gp2"
      volume_size = 8
    },
  ]

  key_name = aws_key_pair.deployer.key_name

  tags = local.tags
}
