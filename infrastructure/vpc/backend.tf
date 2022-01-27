# https://www.terraform.io/docs/language/settings/backends/s3.html
terraform {
  backend "s3" {
    region         = "eu-central-1"
    bucket         = "tfstate-aws-uweeisele-dev"
    key            = "showcase-vpc"
    dynamodb_table = "tfstate-aws-uweeisele-dev"
  }
}
