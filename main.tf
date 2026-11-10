module "eks" {
  source = "./modules/eks"

  cluster_name                       = var.cluster_name
  kubernetes_version                 = var.kubernetes_version
  aws_region                         = var.aws_region
  vpc_cidr                           = var.vpc_cidr
  availability_zones                 = var.availability_zones
  enable_auto_mode                   = var.enable_auto_mode
  sandbox_mode                       = var.sandbox_mode
  confidential_expected_image_digest = var.confidential_expected_image_digest
  deploy_sample_workload             = var.deploy_sample_workload

  tags = merge(
    var.tags,
    {
      Environment = var.environment
    }
  )
}

module "ecs" {
  count  = var.enable_ecs ? 1 : 0
  source = "./modules/ecs"

  cluster_name       = "${var.cluster_name}-ecs"
  environment        = var.environment
  vpc_id             = module.eks.vpc_id
  private_subnet_ids = module.eks.private_subnet_ids
  isolation_mode     = var.sandbox_mode == "confidential" ? "CONFIDENTIAL_SANDBOX" : "ISOLATED_SANDBOX"

  tags = merge(
    var.tags,
    {
      Environment = var.environment
    }
  )
}

module "ec2" {
  count  = var.enable_ec2 ? 1 : 0
  source = "./modules/ec2"

  instance_name = "${var.cluster_name}-host"
  environment   = var.environment
  vpc_id        = module.eks.vpc_id
  subnet_id     = module.eks.private_subnet_ids[0]

  tags = merge(
    var.tags,
    {
      Environment = var.environment
    }
  )
}
