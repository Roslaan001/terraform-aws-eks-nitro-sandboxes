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
