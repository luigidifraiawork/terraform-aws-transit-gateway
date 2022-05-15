provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  name   = "ex-tgw-${replace(basename(path.cwd), "_", "-")}"
  #name   = "tgw-custom-routes"
  region = "us-east-1"

  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  vpc_config = {
    inspection = {
      cidr = "10.1.0.0/16"
      spoke = false
    }
    dev = {
      cidr = "10.2.0.0/16"
      spoke = true
    }
    qa = {
      cidr = "10.3.0.0/16"
      spoke = true
    }
  }

  spokes = [ for i in keys(local.vpc_config) : i if local.vpc_config[i].spoke == true ]

  tgw_routes = keys(local.vpc_config)

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

  #source  = "terraform-aws-modules/transit-gateway/aws"
  #version = "~>2.8.0"

  name            = local.name
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

resource "aws_ec2_transit_gateway_route_table" "tgw_route_tables" {
  for_each = toset(local.tgw_routes)

  transit_gateway_id = module.tgw.ec2_transit_gateway_id

  tags = {
    Name = "${each.key}"
  }
}

################################################################################
# Glue data sources to emulate multi-account resource lookups
################################################################################

data "aws_ec2_transit_gateway_route_table" "tgw_route_tables" {
  for_each = toset(local.tgw_routes)

  filter {
    name   = "tag:Name"
    values = ["${each.key}"]
  }

  depends_on = [aws_ec2_transit_gateway_route_table.tgw_route_tables]
}

################################################################################
# Supporting resources
################################################################################

resource "aws_key_pair" "deployer" {
  key_name   = "${local.name}-deployer"
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

################################################################################
# Network Hub resources
################################################################################

module "vpc_inspection" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "${local.name}-inspection"
  cidr = local.vpc_config.inspection.cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_config.inspection.cidr, 8, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_config.inspection.cidr, 8, k + 10)]

  tags = local.tags
}

resource "aws_route" "inspection_to_tgw_private" {
  count                  = length(module.vpc_inspection.azs)
  route_table_id         = module.vpc_inspection.private_route_table_ids[count.index]
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_inspection,
  ]
}

resource "aws_route" "inspection_to_tgw_public" {
  route_table_id         = module.vpc_inspection.public_route_table_ids[0]
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_inspection,
  ]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachment_inspection" {
  transit_gateway_id = module.tgw.ec2_transit_gateway_id

  # Attach VPC and private subnets to the Transit Gateway
  vpc_id     = module.vpc_inspection.vpc_id
  subnet_ids = module.vpc_inspection.private_subnets

  # Turn off default route table association and propagation, as we're providing our own
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
}

resource "aws_ec2_transit_gateway_route_table_association" "tgw_route_association_inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_inspection.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.tgw_route_tables["inspection"].id
  #transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rts["inspection"].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_spokes_to_inspection" {
  for_each = toset(local.spokes)

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_inspection.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.tgw_route_tables[each.key].id
}

module "security_group_inspection" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-inspection"
  description = "Security group for usage with EC2 instances"
  vpc_id      = module.vpc_inspection.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["ssh-tcp"]
  egress_rules        = ["all-all"]

  tags = local.tags
}

module "ec2_inspection" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 4.0.0"

  name = "${local.name}-inspection"

  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t2.micro"
  availability_zone           = element(module.vpc_inspection.azs, 0)
  subnet_id                   = element(module.vpc_inspection.public_subnets, 0)
  vpc_security_group_ids      = [module.security_group_inspection.security_group_id]
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

################################################################################
# Dev Spoke resources
################################################################################

module "vpc_dev" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "${local.name}-dev"
  cidr = local.vpc_config.dev.cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_config.dev.cidr, 8, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_config.dev.cidr, 8, k + 10)]

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

resource "aws_ec2_transit_gateway_route_table_association" "tgw_route_association_dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_dev.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.tgw_route_tables["dev"].id
  #transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rts["dev"].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_inspection_to_dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_dev.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.tgw_route_tables["inspection"].id
  #transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rts["inspection"].id
}

module "security_group_dev" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-dev"
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

  name = "${local.name}-dev"

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

################################################################################
# QA Spoke resources
################################################################################

module "vpc_qa" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 3.0"

  name = "${local.name}-qa"
  cidr = local.vpc_config.qa.cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_config.qa.cidr, 8, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_config.qa.cidr, 8, k + 10)]

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

resource "aws_ec2_transit_gateway_route_table_association" "tgw_route_association_qa" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_qa.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.tgw_route_tables["qa"].id
  #transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rts["qa"].id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "tgw_route_propagation_inspection_to_qa" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment_qa.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.tgw_route_tables["inspection"].id
  #transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rts["inspection"].id
}

module "security_group_qa" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-qa"
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

  name = "${local.name}-qa"

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
