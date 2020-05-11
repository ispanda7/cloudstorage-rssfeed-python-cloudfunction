locals {
  project = "project-test-270001"
  region  = "us-central1"
  zone    = "us-central1-c"
}

# Specify the GCP Provider
provider "google" {
  credentials = file("credentials.json")
  project     = local.project
  region      = local.region
  zone        = local.zone
}

# zip up our source code
data "archive_file" "insert_data" {
 type        = "zip"
 output_path = "${path.module}/insert_data.zip"

 source {
    content  = file("${path.module}/source_code/insert_data.py")
    filename = "main.py"
  }

  source {
    content  = file("${path.module}/source_code/requirements.txt")
    filename = "requirements.txt"
  }
}

data "archive_file" "generate_rssfeed" {
 type        = "zip"
 output_path = "${path.module}/generate_rssfeed.zip"

 source {
    content  = file("${path.module}/source_code/generate_rssfeed.py")
    filename = "main.py"
  }

  source {
    content  = file("${path.module}/source_code/requirements.txt")
    filename = "requirements.txt"
  }
}

data "archive_file" "convert_xml_to_json" {
 type        = "zip"
 output_path = "${path.module}/convert_xml_to_json.zip"

 source {
    content  = file("${path.module}/source_code/convert_xml_to_json.py")
    filename = "main.py"
  }

  source {
    content  = file("${path.module}/source_code/requirements.txt")
    filename = "requirements.txt"
  }
}


# cloud storage service
resource "google_storage_bucket" "source_code_file" {
  name    = "source_code_file"
  location  = local.region
  force_destroy = true
}

resource "google_storage_bucket_access_control" "public_rule" {
  bucket = "${google_storage_bucket.image_file_general.name}"
  role   = "READER"
  entity = "allUsers"
}

resource "google_storage_bucket" "image_file_general" {
  name    = "image_file_general"
  location  = local.region
  force_destroy = true
}

# place the zip-ed code in the bucket
resource "google_storage_bucket_object" "insert_data" {
 name   = "insert_data.zip"
 bucket = "${google_storage_bucket.source_code_file.name}"
 source = "${path.module}/insert_data.zip"
}

resource "google_storage_bucket_object" "generate_rssfeed" {
 name   = "generate_rssfeed.zip"
 bucket = "${google_storage_bucket.source_code_file.name}"
 source = "${path.module}/generate_rssfeed.zip"
}

resource "google_storage_bucket_object" "convert_xml_to_json" {
 name   = "convert_xml_to_json.zip"
 bucket = "${google_storage_bucket.source_code_file.name}"
 source = "${path.module}/convert_xml_to_json.zip"
}

# cloud functions service
resource "google_cloudfunctions_function" "function_insert_data" {
  name        = "function_insert_data"
  description = "My function"
  runtime     = "python37"

  available_memory_mb   = 128
  source_archive_bucket = "${google_storage_bucket.source_code_file.name}"
  source_archive_object = "${google_storage_bucket_object.insert_data.name}"
  trigger_http          = true
  entry_point           = "main"
  environment_variables = {
    collection = "image_file_details"
    DESTINATION_BUCKET = "image_file_general"
  }
}

resource "google_cloudfunctions_function" "function_generate_rssfeed" {
  name        = "function_generate_rssfeed"
  description = "My function"
  runtime     = "python37"

  available_memory_mb   = 128
  source_archive_bucket = "${google_storage_bucket.source_code_file.name}"
  source_archive_object = "${google_storage_bucket_object.generate_rssfeed.name}"
  entry_point           = "main"
  event_trigger {
    event_type = "providers/cloud.firestore/eventTypes/document.write"
    resource = "image_file_details/{document}"
  }
  environment_variables = {
    collection = "image_file_details"
    DESTINATION_BUCKET = "image_file_general"
  }
}

resource "google_cloudfunctions_function" "function_convert_xml_to_json" {
  name        = "function_convert_xml_to_json"
  description = "My function"
  runtime     = "python37"

  available_memory_mb   = 128
  source_archive_bucket = "${google_storage_bucket.source_code_file.name}"
  source_archive_object = "${google_storage_bucket_object.convert_xml_to_json.name}"
  trigger_http          = true
  entry_point           = "convert"
  environment_variables = {
    DESTINATION_BUCKET = "image_file_general"
  }
}

# cloud run service
resource "google_cloud_run_service" "cloudrunsrv" {
  name     = "cloudrunsrv"
  location = local.region

  template {
    spec {
      containers {
        image = "gcr.io/endpoints-release/endpoints-runtime-serverless:2"
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

# cloud endpoints service, replacing host and address functions values on openapi file
resource "google_endpoints_service" "openapi_service" {  
    service_name   = replace(
      "${google_cloud_run_service.cloudrunsrv.status[0].url}",
      "https://",
      ""
    )
    openapi_config = templatefile("${path.module}/openapi-functions.yaml", {
        cloud_run_hostname = replace(
          "${google_cloud_run_service.cloudrunsrv.status[0].url}",
          "https://",
          ""
        ),
        inserdata_functionurl = google_cloudfunctions_function.function_insert_data.https_trigger_url,
        getjson_functionurl = google_cloudfunctions_function.function_convert_xml_to_json.https_trigger_url
    })
}

# local-exec for building a new espv2 beta image and redeploy the ESPv2 Beta Cloud Run service with the new image
resource "null_resource" "building_new_image" {
  provisioner "local-exec" {
    command = <<EOF
      chmod +x gcloud_build_image;

      ./gcloud_build_image -s $cloud_run_hostname -c $config_id -p ${local.project};

      gcloud run deploy $cloud_run_service_name \
      --image="gcr.io/${local.project}/endpoints-runtime-serverless:$cloud_run_hostname-$config_id" \
      --allow-unauthenticated \
      --platform managed \
      --project=${local.project}
      EOF
    environment = {
      config_id = "${google_endpoints_service.openapi_service.config_id}"
      cloud_run_service_name = "${google_cloud_run_service.cloudrunsrv.name}"
      cloud_run_hostname = "${google_endpoints_service.openapi_service.service_name}"
    }
  }
}