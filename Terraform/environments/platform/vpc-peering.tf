##############################################################################
# VPC Peering — platform <-> dev and platform <-> prod
# Enables Grafana on platform to reach monitoring backends on dev/prod
# via private AWS networking — no public endpoints needed.
##############################################################################

# ---------------------------------------------------------------
# Platform <-> Dev peering
# ---------------------------------------------------------------
data "aws_vpc" "dev" {
  tags = { Name = "ecommerce-dev-vpc" }
}

resource "aws_vpc_peering_connection" "platform_dev" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.aws_vpc.dev.id
  auto_accept = true

  tags = { Name = "ecommerce-platform-dev-peering" }
}

# Route tables in platform VPC
data "aws_route_tables" "platform_private" {
  vpc_id = module.vpc.vpc_id
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

data "aws_route_tables" "platform_public" {
  vpc_id = module.vpc.vpc_id
  filter {
    name   = "tag:Name"
    values = ["*public*"]
  }
}

# Routes: platform -> dev
resource "aws_route" "platform_to_dev_private" {
  count                     = length(data.aws_route_tables.platform_private.ids)
  route_table_id            = tolist(data.aws_route_tables.platform_private.ids)[count.index]
  destination_cidr_block    = data.aws_vpc.dev.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_dev.id
}

resource "aws_route" "platform_to_dev_public" {
  count                     = length(data.aws_route_tables.platform_public.ids)
  route_table_id            = tolist(data.aws_route_tables.platform_public.ids)[count.index]
  destination_cidr_block    = data.aws_vpc.dev.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_dev.id
}

# Route tables in dev VPC
data "aws_route_tables" "dev_private" {
  vpc_id = data.aws_vpc.dev.id
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

data "aws_route_tables" "dev_public" {
  vpc_id = data.aws_vpc.dev.id
  filter {
    name   = "tag:Name"
    values = ["*public*"]
  }
}

# Routes: dev -> platform
resource "aws_route" "dev_to_platform_private" {
  count                     = length(data.aws_route_tables.dev_private.ids)
  route_table_id            = tolist(data.aws_route_tables.dev_private.ids)[count.index]
  destination_cidr_block    = module.vpc.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_dev.id
}

resource "aws_route" "dev_to_platform_public" {
  count                     = length(data.aws_route_tables.dev_public.ids)
  route_table_id            = tolist(data.aws_route_tables.dev_public.ids)[count.index]
  destination_cidr_block    = module.vpc.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_dev.id
}

# ---------------------------------------------------------------
# Platform <-> Prod peering
# ---------------------------------------------------------------
data "aws_vpc" "prod" {
  tags = { Name = "ecommerce-prod-vpc" }
}

resource "aws_vpc_peering_connection" "platform_prod" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.aws_vpc.prod.id
  auto_accept = true

  tags = { Name = "ecommerce-platform-prod-peering" }
}

# Routes: platform -> prod
resource "aws_route" "platform_to_prod_private" {
  count                     = length(data.aws_route_tables.platform_private.ids)
  route_table_id            = tolist(data.aws_route_tables.platform_private.ids)[count.index]
  destination_cidr_block    = data.aws_vpc.prod.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_prod.id
}

resource "aws_route" "platform_to_prod_public" {
  count                     = length(data.aws_route_tables.platform_public.ids)
  route_table_id            = tolist(data.aws_route_tables.platform_public.ids)[count.index]
  destination_cidr_block    = data.aws_vpc.prod.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_prod.id
}

# Route tables in prod VPC
data "aws_route_tables" "prod_private" {
  vpc_id = data.aws_vpc.prod.id
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

data "aws_route_tables" "prod_public" {
  vpc_id = data.aws_vpc.prod.id
  filter {
    name   = "tag:Name"
    values = ["*public*"]
  }
}

# Routes: prod -> platform
resource "aws_route" "prod_to_platform_private" {
  count                     = length(data.aws_route_tables.prod_private.ids)
  route_table_id            = tolist(data.aws_route_tables.prod_private.ids)[count.index]
  destination_cidr_block    = module.vpc.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_prod.id
}

resource "aws_route" "prod_to_platform_public" {
  count                     = length(data.aws_route_tables.prod_public.ids)
  route_table_id            = tolist(data.aws_route_tables.prod_public.ids)[count.index]
  destination_cidr_block    = module.vpc.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.platform_prod.id
}
