terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">= 0.126.0"
    }
  }
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.zone
}


# 1. Network / Subnet
resource "yandex_vpc_network" "main" {
  name = "main-network"
}

resource "yandex_vpc_subnet" "public" {
  name           = "public-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = ["10.1.0.0/24"]
}


# 2. Object Storage Bucket
resource "yandex_storage_bucket" "bucket" {
  folder_id     = var.folder_id
  bucket        = var.bucket_name
  force_destroy = true
}

resource "yandex_storage_bucket_iam_binding" "public_access" {
  bucket  = yandex_storage_bucket.bucket.bucket
  role    = "storage.viewer"
  members = ["system:allUsers"]
}

resource "yandex_storage_object" "image" {
  bucket = yandex_storage_bucket.bucket.bucket
  key    = "image.jpg"
  source = var.image_path
}


# 3. Instance Group (LAMP)
resource "yandex_compute_instance_group" "lamp_group" {
  name               = "lamp-group1"
  folder_id          = var.folder_id
  service_account_id = var.sa_id

  instance_template {
    platform_id = "standard-v3"

    resources {
      memory = 2
      cores  = 2
    }

    boot_disk {
      initialize_params {
        image_id = "fd827b91d99psvq5fjit"
        size     = 20
      }
    }

    network_interface {
      subnet_ids = [yandex_vpc_subnet.public.id]
      nat        = true
    }

    metadata = {
      user-data = <<EOF
#!/bin/bash
cat <<HTML >/var/www/html/index.html
<html>
  <body>
    <h1>Netology!</h1>
    <img src="https://${var.bucket_name}.storage.yandexcloud.net/image.jpg" width="400">
  </body>
</html>
HTML
EOF
    }
  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  allocation_policy {
    zones = [var.zone]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 1
  }

  health_check {
    interval = 30
    timeout  = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3

    tcp_options {
      port = 80
    }
  }

  load_balancer {
    target_group_name = "lamp-target-group"
  }
}


# 4. Network Load Balancer
resource "yandex_lb_network_load_balancer" "nlb" {
  depends_on = [yandex_compute_instance_group.lamp_group]

  name = "lamp-nlb"

  listener {
    name = "http"
    port = 80
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.lamp_group.load_balancer[0].target_group_id

    healthcheck {
      name = "http-hc"
      http_options {
        port = 80
        path = "/"
      }
    }
  }
}



# 5. Outputs

output "bucket_image_url" {
  value       = "https://${yandex_storage_bucket.bucket.bucket}.storage.yandexcloud.net/image.jpg"
}

locals {
  nlb_ips = [
    for l in yandex_lb_network_load_balancer.nlb.listener : 
    length(tolist(l.external_address_spec)) > 0 ? tolist(l.external_address_spec)[0].address : null
  ]

  nlb_ip_first = [for ip in local.nlb_ips : ip if ip != null][0]
}

output "nlb_ip" {
  value       = local.nlb_ip_first
}
