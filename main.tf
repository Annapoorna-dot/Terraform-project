terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "ap-south-1"
}
resource "aws_vpc" "my_vpc" {
  cidr_block       = "107.25.0.0/16"
  enable_dns_hostnames = true

  tags = {
    Name = "My VPC"
  }
}
resource "aws_subnet" "public1" {
  vpc_id     = aws_vpc.my_vpc.id
  cidr_block = "107.25.1.0/24"
  availability_zone = "ap-south-1a"

  tags = {
    Name = "Public Subnet 1"
  }
}

resource "aws_subnet" "public2" {
  vpc_id     = aws_vpc.my_vpc.id
  cidr_block = "107.25.2.0/24"
  availability_zone = "ap-south-1b"

  tags = {
    Name = "Public Subnet 2"
  }
}

resource "aws_internet_gateway" "my_vpc_igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "My VPC - Internet Gateway"
  }
}

resource "aws_route_table" "my_vpc_public" {
    vpc_id = aws_vpc.my_vpc.id

    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.my_vpc_igw.id
    }

    tags = {
        Name = "Public Subnets Route Table for My VPC"
    }
}

resource "aws_route_table_association" "my_vpc_ap-south_1_public" {
    subnet_id = aws_subnet.public1.id
    route_table_id = aws_route_table.my_vpc_public.id
}

resource "aws_route_table_association" "my_vpc_ap_south_1b_public" {
    subnet_id = aws_subnet.public2.id
    route_table_id = aws_route_table.my_vpc_public.id
}

resource "aws_security_group" "allow_http" {
  name        = "allow_http"
  description = "Allow all tcp inbound connections"
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Allow ALL TCP"
  }
}

resource "aws_launch_configuration" "web" {
  name_prefix = "web-"

  image_id = "ami-074dc0a6f6c764218" # Amazon Linux 2 AMI (HVM), SSD Volume Type
  instance_type = "t2.micro"
  key_name = "awskey"

  security_groups = [ aws_security_group.allow_http.id ]
  associate_public_ip_address = true

 user_data = <<-EOF
              #!/bin/bash
              sudo yum -y install httpd
              sudo service httpd start
              echo "Hello, from Terraform" > /var/www/html/index.html
              chkconfig httpd on
              EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "elb_http" {
  name        = "elb_http"
  description = "Allow HTTP traffic to instances through Elastic Load Balancer"
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Allow all tcp"
  }
}

resource "aws_elb" "web_elb" {
  name = "web-elb"
  security_groups = [
    aws_security_group.elb_http.id
  ]
  subnets = [
    aws_subnet.public1.id,
    aws_subnet.public2.id
  ]

  cross_zone_load_balancing   = true

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    interval = 30
    target = "HTTP:80/"
  }

  listener {
    lb_port = 80
    lb_protocol = "http"
    instance_port = "80"
    instance_protocol = "http"
  }

}

resource "aws_autoscaling_group" "web" {
  name = "${aws_launch_configuration.web.name}-asg"

  min_size             = 1
  desired_capacity     = 2
  max_size             = 4
  
  health_check_type    = "ELB"
  load_balancers = [
    aws_elb.web_elb.id
  ]

  launch_configuration = aws_launch_configuration.web.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier  = [
    aws_subnet.public1.id,
    aws_subnet.public2.id
  ]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "web"
    propagate_at_launch = true
  }

}

output "elb_dns_name" {
  value = aws_elb.web_elb.dns_name
}
