variable "public_key" {
  description = "Public key to register with AWS to allow logging-in to EC2 instances"
  type        = string
}

variable "vpc_config" {
  description = "Map of objects for per VPC configuration"

  type = map(object({
    cidr  = string
    spoke = bool
  }))

  default = {
    inspection = {
      cidr = "10.1.0.0/16"
      spoke = false
    }
    dev = {
      cidr = "10.2.0.0/16"
      spoke = true
    }
    qa = {
      cidr = "10.3.0.0/16"
      spoke = true
    }
  }
}

variable "source_cidr_block" {
  description = "Local IP for securing SSH access to EC2 instances over the Internet"
  type        = string
  default     = "0.0.0.0/0"
}
