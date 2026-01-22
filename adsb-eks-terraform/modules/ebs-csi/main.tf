# modules/ebs-csi/main.tf
# EBS CSI Driver for EKS persistent volumes
# Uses IRSA (IAM Roles for Service Accounts) for permissions

# IAM role for EBS CSI driver
data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.cluster_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.cluster_oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.cluster_oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = {
    Name = "${var.cluster_name}-ebs-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

# Install EBS CSI driver via Helm
resource "helm_release" "ebs_csi_driver" {
  name       = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  version    = "2.37.0"  # Latest stable as of Jan 2025
  namespace  = "kube-system"

  set {
    name  = "controller.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "controller.serviceAccount.name"
    value = "ebs-csi-controller-sa"
  }

  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.ebs_csi.arn
  }

  # Enable volume snapshot support
  set {
    name  = "enableVolumeSnapshot"
    value = "true"
  }

  # Use Graviton/ARM64 compatible images
  set {
    name  = "image.repository"
    value = "public.ecr.aws/ebs-csi-driver/aws-ebs-csi-driver"
  }

  set {
    name  = "sidecars.provisioner.image.repository"
    value = "public.ecr.aws/eks-distro/kubernetes-csi/external-provisioner"
  }

  set {
    name  = "sidecars.attacher.image.repository"
    value = "public.ecr.aws/eks-distro/kubernetes-csi/external-attacher"
  }

  set {
    name  = "sidecars.resizer.image.repository"
    value = "public.ecr.aws/eks-distro/kubernetes-csi/external-resizer"
  }

  set {
    name  = "sidecars.snapshotter.image.repository"
    value = "public.ecr.aws/eks-distro/kubernetes-csi/external-snapshotter/csi-snapshotter"
  }

  set {
    name  = "sidecars.livenessProbe.image.repository"
    value = "public.ecr.aws/eks-distro/kubernetes-csi/livenessprobe"
  }

  set {
    name  = "sidecars.nodeDriverRegistrar.image.repository"
    value = "public.ecr.aws/eks-distro/kubernetes-csi/node-driver-registrar"
  }
}
