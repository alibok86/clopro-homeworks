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

# 1. Создаём KMS ключ
resource "yandex_kms_symmetric_key" "kms_key" {
  name              = "bucket-encryption-key"
  description       = "KMS key for bucket encryption"
  default_algorithm = "AES_256"
  rotation_period   = "8760h"
  folder_id         = var.folder_id
}

# 2. Даем сервисному аккаунту право шифровать объекты
resource "yandex_kms_symmetric_key_iam_binding" "kms_usage" {
  symmetric_key_id = yandex_kms_symmetric_key.kms_key.id
  role             = "kms.keys.encrypterDecrypter"
  members          = ["serviceAccount:${var.sa_id}"]
}

# 3. Создаём бакет с шифрованием KMS
resource "yandex_storage_bucket" "bucket" {
  depends_on = [
    yandex_kms_symmetric_key.kms_key,
    yandex_kms_symmetric_key_iam_binding.kms_usage
  ]

  folder_id = var.folder_id
  bucket    = var.bucket_name
  force_destroy = true

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = yandex_kms_symmetric_key.kms_key.id
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

# 4. Делаем бакет публичным для чтения
resource "yandex_storage_bucket_iam_binding" "public_access" {
  bucket  = yandex_storage_bucket.bucket.bucket
  role    = "storage.viewer"
  members = ["system:allUsers"]
}

# 5. Загружаем зашифрованный объект image.jpg
resource "yandex_storage_object" "image" {
  depends_on = [
    yandex_storage_bucket.bucket,
    yandex_storage_bucket_iam_binding.public_access
  ]

  bucket = yandex_storage_bucket.bucket.bucket
  key    = "image.jpg"
  source = var.image_path
}

# 6. Вывод ссылки на объект
output "bucket_image_url" {
  value = "https://${yandex_storage_bucket.bucket.bucket}.storage.yandexcloud.net/image.jpg"
}
