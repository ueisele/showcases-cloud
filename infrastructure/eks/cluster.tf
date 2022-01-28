#################################
# EKS Cluster                   #
#################################

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster
resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-${var.module}"
  role_arn = aws_iam_role.eks-cluster.arn

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
    subnet_ids              = data.aws_subnet_ids.private.ids
    security_group_ids      = [aws_security_group.eks-cluster.id, aws_security_group.eks-node-group.id]
  }

  tags = {
    Name        = "${var.environment}-${var.module}"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.eks-cluster-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks-cluster-AmazonEKSVPCResourceController,
  ]
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role
resource "aws_iam_role" "eks-cluster" {
  name = "${var.environment}-${var.module}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "eks.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.environment}-${var.module}-cluster"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
resource "aws_iam_role_policy_attachment" "eks-cluster-AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks-cluster.name
}

# Optionally, enable Security Groups for Pods
# Reference: https://docs.aws.amazon.com/eks/latest/userguide/security-groups-for-pods.html
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
resource "aws_iam_role_policy_attachment" "eks-cluster-AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks-cluster.name
}

#############################################
# EKS IRSA (IAM Roles for Service Accounts) #
#############################################
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster#enabling-iam-roles-for-service-accounts

# https://registry.terraform.io/providers/hashicorp/tls/latest/docs/data-sources/tls_certificate
data "tls_certificate" "eks-cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider
resource "aws_iam_openid_connect_provider" "eks-cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks-cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.environment}-${var.module}-irsa"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

#################################
# VPC Tags                      #
#################################

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_tag
resource "aws_ec2_tag" "vpc-eks-cluster" {
  resource_id = data.aws_vpc.main.id
  key         = "kubernetes.io/cluster/${aws_eks_cluster.main.name}"
  value       = "shared"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_tag
resource "aws_ec2_tag" "public-subnets-eks-cluster" {
  count = length(data.aws_subnet_ids.public.ids)

  resource_id = element(tolist(data.aws_subnet_ids.public.ids), count.index)
  key         = "kubernetes.io/cluster/${aws_eks_cluster.main.name}"
  value       = "shared"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_tag
resource "aws_ec2_tag" "private-subnets-eks-cluster" {
  count = length(data.aws_subnet_ids.private.ids)

  resource_id = element(tolist(data.aws_subnet_ids.private.ids), count.index)
  key         = "kubernetes.io/cluster/${aws_eks_cluster.main.name}"
  value       = "shared"
}

#################################
# EKS Fargate Profile           #
#################################

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_fargate_profile
resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "${var.environment}-${var.module}-default"
  pod_execution_role_arn = aws_iam_role.eks-fargate-profile.arn
  subnet_ids             = data.aws_subnet_ids.private.ids

  selector {
    namespace = "default"
  }

  tags = {
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks-fargate-profile-AmazonEKSFargatePodExecutionRolePolicy,
  ]
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role
resource "aws_iam_role" "eks-fargate-profile" {
  name = "${var.environment}-${var.module}-fargate-profile"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment
resource "aws_iam_role_policy_attachment" "eks-fargate-profile-AmazonEKSFargatePodExecutionRolePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.eks-fargate-profile.name
}

output "eks-fargate-profile-role-arn" {
  value = aws_iam_role.eks-fargate-profile.arn
}

#################################
# EKS Node Groups               #
#################################

# System Node Group

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${aws_eks_cluster.main.name}-system"
  node_role_arn   = aws_iam_role.eks-node-group.arn
  subnet_ids      = data.aws_subnet_ids.private.ids

  ami_type       = "BOTTLEROCKET_ARM_64"
  instance_types = ["t4g.small"]
  disk_size      = 20

  scaling_config {
    max_size     = 9
    min_size     = 1
    desired_size = 3
  }

  # Optional: Allow external changes without Terraform plan difference
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  update_config {
    max_unavailable = 2
  }

  taint {
    key    = "system"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Environment                                              = var.environment
    Module                                                   = var.module
    Terraform                                                = "true"
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.eks-node-group-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks-node-group-AmazonEC2ContainerRegistryReadOnly,
  ]
}

# Main x64

resource "aws_eks_node_group" "main_x64" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${aws_eks_cluster.main.name}-main-x64"
  node_role_arn   = aws_iam_role.eks-node-group.arn
  subnet_ids      = data.aws_subnet_ids.private.ids

  ami_type       = "BOTTLEROCKET_x86_64"
  instance_types = ["t3a.medium"]
  disk_size      = 20

  scaling_config {
    max_size     = 9
    min_size     = 0
    desired_size = 0
  }

  # Optional: Allow external changes without Terraform plan difference
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  update_config {
    max_unavailable = 2
  }

  tags = {
    Environment                                              = var.environment
    Module                                                   = var.module
    Terraform                                                = "true"
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.eks-node-group-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks-node-group-AmazonEC2ContainerRegistryReadOnly,
  ]
}

# Main arm64

resource "aws_eks_node_group" "main_arm64" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${aws_eks_cluster.main.name}-main-arm64"
  node_role_arn   = aws_iam_role.eks-node-group.arn
  subnet_ids      = data.aws_subnet_ids.private.ids

  ami_type       = "BOTTLEROCKET_ARM_64"
  instance_types = ["t4g.medium"]
  disk_size      = 20

  scaling_config {
    max_size     = 9
    min_size     = 0
    desired_size = 0
  }

  # Optional: Allow external changes without Terraform plan difference
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  update_config {
    max_unavailable = 2
  }

  tags = {
    Environment                                              = var.environment
    Module                                                   = var.module
    Terraform                                                = "true"
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.eks-node-group-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.eks-node-group-AmazonEC2ContainerRegistryReadOnly,
  ]
}

# IAM

resource "aws_iam_role" "eks-node-group" {
  name = "${var.environment}-${var.module}-node-group"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })

  tags = {
    Name        = "${var.environment}-${var.module}-node-group"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

resource "aws_iam_role_policy_attachment" "eks-node-group-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks-node-group.name
}

resource "aws_iam_role_policy_attachment" "eks-node-group-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks-node-group.name
}

resource "aws_iam_role_policy_attachment" "eks-node-group-AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks-node-group.name
}

output "eks-node-group-role-arn" {
  value = aws_iam_role.eks-node-group.arn
}

#################################
# EKS Addons                    #
#################################
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon
# VPC-CNI (https://docs.aws.amazon.com/eks/latest/userguide/managing-vpc-cni.html)

data "aws_iam_policy_document" "vpn-cni-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks-cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks-cluster.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "vpn-cni-assume-role" {
  assume_role_policy = data.aws_iam_policy_document.vpn-cni-assume-role-policy.json
  name               = "${var.environment}-${var.module}-vpn-cni-assume-role"
}

resource "aws_iam_role_policy_attachment" "vpn-cni-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpn-cni-assume-role.name
}

resource "aws_eks_addon" "vpc-cni" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "vpc-cni"
  service_account_role_arn = aws_iam_role.vpn-cni-assume-role.arn
  resolve_conflicts        = "OVERWRITE"
  tags = {
    eks_addon   = "vpc-cni"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

# Kube-Proxy

resource "aws_eks_addon" "kube-proxy" {
  cluster_name      = aws_eks_cluster.main.name
  addon_name        = "kube-proxy"
  resolve_conflicts = "OVERWRITE"
  tags = {
    eks_addon   = "kube-proxy"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

#################################
# Security Groups               #
#################################

# Cluster Security Group

resource "aws_security_group" "eks-cluster" {
  name        = "${var.environment}-${var.module}-cluster"
  description = "Cluster communication with worker nodes"
  vpc_id      = data.aws_vpc.main.id
  tags = {
    Name        = "${var.environment}-${var.module}-cluster"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

resource "aws_security_group_rule" "nodes-inbound" {
  description              = "Allow worker nodes to communicate with the cluster API Server"
  from_port                = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks-cluster.id
  source_security_group_id = aws_security_group.eks-node-group.id
  to_port                  = 443
  type                     = "ingress"
}

resource "aws_security_group_rule" "nodes-outbound" {
  description              = "Allow cluster API Server to communicate with the worker nodes"
  from_port                = 1024
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks-cluster.id
  source_security_group_id = aws_security_group.eks-node-group.id
  to_port                  = 65535
  type                     = "egress"
}

# Worker Security Group

resource "aws_security_group" "eks-node-group" {
  name        = "${var.environment}-${var.module}-node-group"
  description = "Security group for all nodes in the cluster"
  vpc_id      = data.aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name        = "${var.environment}-${var.module}-node-group"
    Environment = var.environment
    Module      = var.module
    Terraform   = "true"
  }
}

resource "aws_ec2_tag" "sg-eks-node-group" {
  resource_id = aws_security_group.eks-node-group.id
  key         = "kubernetes.io/cluster/${aws_eks_cluster.main.name}"
  value       = "owned"
}

resource "aws_security_group_rule" "nodes" {
  description              = "Allow nodes to communicate with each other"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks-node-group.id
  source_security_group_id = aws_security_group.eks-node-group.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "cluster-inbound" {
  description              = "Allow worker Kubelets and pods to receive communication from the cluster control plane"
  from_port                = 1025
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks-node-group.id
  source_security_group_id = aws_security_group.eks-cluster.id
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "private-inbound" {
  description              = "Allow inbound from private subnets"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks-node-group.id
  source_security_group_id = tolist(data.aws_security_groups.private.ids)[0]
  to_port                  = 65535
  type                     = "ingress"
}

resource "aws_security_group_rule" "public-inbound" {
  description              = "Allow inbound from public subnets"
  from_port                = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks-node-group.id
  source_security_group_id = tolist(data.aws_security_groups.public.ids)[0]
  to_port                  = 65535
  type                     = "ingress"
}
