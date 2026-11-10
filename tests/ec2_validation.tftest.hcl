# Terraform Test: EC2 Nitro Sandbox Host Module Validation

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
}

variables {
  instance_name         = "test-nitro-host"
  environment           = "test"
  vpc_id                = "vpc-12345678"
  subnet_id             = "subnet-11111111"
  instance_type         = "c6i.xlarge"
  enable_nitro_enclaves = true
}

run "validate_ec2_nitro_host_security_and_enclaves" {
  command = plan

  module {
    source = "./modules/ec2"
  }

  assert {
    condition     = aws_instance.nitro_host.enclave_options[0].enabled == true
    error_message = "Nitro Enclaves must be enabled on the EC2 instance."
  }

  assert {
    condition     = aws_instance.nitro_host.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be strictly required on the EC2 host."
  }

  assert {
    condition     = aws_instance.nitro_host.root_block_device[0].encrypted == true
    error_message = "Root block device must be encrypted."
  }
}
