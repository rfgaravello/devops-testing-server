terraform {
  backend "s3" {
    bucket = "24devopsterraformstate09"
    key    = "terraform.tfstate"
    region = "ap-southeast-2"
    encrypt = true
  }
}
