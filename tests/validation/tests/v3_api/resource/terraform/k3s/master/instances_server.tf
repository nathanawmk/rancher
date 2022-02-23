resource "aws_db_parameter_group" "db-parameters" {
  name   = "${var.resource_name}-dbparameter"
  family = var.db_group_name
  parameter {
    apply_method = "pending-reboot"
    name         = "max_connections"
    value        = var.max_connections
  }
  tags = {
    yor_trace = "03802423-c814-4df7-bea4-d33e71456054"
  }
}

resource "aws_db_instance" "db" {
  count             = (var.cluster_type == "etcd" ? 0 : (var.external_db != "aurora-mysql" ? 1 : 0))
  identifier        = "${var.resource_name}-db"
  allocated_storage = 20
  storage_type      = "gp2"
  engine            = var.external_db
  engine_version    = var.external_db_version
  instance_class    = var.instance_class
  name              = "mydb"
  #parameter_group_name   = var.db_group_name
  username             = var.db_username
  password             = var.db_password
  availability_zone    = var.availability_zone
  parameter_group_name = "${aws_db_parameter_group.db-parameters.name}"
  tags = {
    Environment = var.environment
    yor_trace   = "172c8560-3c46-4507-b169-6e577c37cd07"
  }
  skip_final_snapshot = true
}

resource "aws_rds_cluster" "db" {
  count              = (var.external_db == "aurora-mysql" ? 1 : 0)
  cluster_identifier = "${var.resource_name}-db"
  engine             = var.external_db
  engine_version     = var.external_db_version
  availability_zones = [var.availability_zone]
  database_name      = "mydb"
  master_username    = var.db_username
  master_password    = var.db_password
  engine_mode        = var.engine_mode
  tags = {
    Environment = var.environment
    yor_trace   = "576b749a-e5a9-4f86-9fc5-1a3650df531e"
  }
  skip_final_snapshot = true
}

resource "aws_rds_cluster_instance" "db" {
  count = (var.external_db == "aurora-mysql" ? 1 : 0)
  #count                  = "${var.external_db == "aurora-mysql" ? 1 : 0}"
  cluster_identifier = "${aws_rds_cluster.db[0].id}"
  identifier         = "${var.resource_name}-instance1"
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.db[0].engine
  engine_version     = aws_rds_cluster.db[0].engine_version
  tags = {
    yor_trace = "4f3ef22c-a449-4dbc-99ee-d4ffe1613680"
  }
}

resource "aws_instance" "master" {
  ami           = var.aws_ami
  instance_type = var.ec2_instance_class
  connection {
    type        = "ssh"
    user        = var.aws_user
    host        = self.public_ip
    private_key = file(var.access_key)
  }
  root_block_device {
    volume_size = var.volume_size
    volume_type = "standard"
  }
  subnet_id              = var.subnets
  availability_zone      = var.availability_zone
  vpc_security_group_ids = [var.sg_id]
  key_name               = "jenkins-rke-validation"
  tags = {
    Name      = "${var.resource_name}-server"
    yor_trace = "c956ee52-c04a-4ecd-bc5c-1729b5563f62"
  }

  provisioner "file" {
    source      = "install_k3s_master.sh"
    destination = "/tmp/install_k3s_master.sh"
  }

  provisioner "file" {
    source      = "cis_masterconfig.yaml"
    destination = "/tmp/cis_masterconfig.yaml"
  }

  provisioner "file" {
    source      = "policy.yaml"
    destination = "/tmp/policy.yaml"
  }

  provisioner "file" {
    source      = "nginx-ingress.yaml"
    destination = "/tmp/nginx-ingress.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/install_k3s_master.sh",
      "sudo /tmp/install_k3s_master.sh ${var.node_os} ${aws_route53_record.aws_route53.fqdn} ${var.install_mode} ${var.k3s_version} ${var.cluster_type} ${self.public_ip} \"${data.template_file.test.rendered}\" \"${var.server_flags}\"  ${var.username} ${var.password}",
    ]
  }

  provisioner "local-exec" {
    command = "echo ${aws_instance.master.public_ip} >/tmp/${var.resource_name}_master_ip"
  }
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.access_key} ${var.aws_user}@${aws_instance.master.public_ip}:/tmp/nodetoken /tmp/${var.resource_name}_nodetoken"
  }
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.access_key} ${var.aws_user}@${aws_instance.master.public_ip}:/tmp/config /tmp/${var.resource_name}_config"
  }
  provisioner "local-exec" {
    command = "scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${var.access_key} ${var.aws_user}@${aws_instance.master.public_ip}:/tmp/joinflags /tmp/${var.resource_name}_joinflags"
  }
  provisioner "local-exec" {
    command = "sed s/127.0.0.1/\"${aws_route53_record.aws_route53.fqdn}\"/g /tmp/${var.resource_name}_config >/tmp/${var.resource_name}_kubeconfig"
  }
}

data "template_file" "test" {
  template   = (var.cluster_type == "etcd" ? "NULL" : (var.external_db == "postgres" ? "postgres://${aws_db_instance.db[0].username}:${aws_db_instance.db[0].password}@${aws_db_instance.db[0].endpoint}/${aws_db_instance.db[0].name}" : (var.external_db == "aurora-mysql" ? "mysql://${aws_rds_cluster.db[0].master_username}:${aws_rds_cluster.db[0].master_password}@tcp(${aws_rds_cluster.db[0].endpoint})/${aws_rds_cluster.db[0].database_name}" : "mysql://${aws_db_instance.db[0].username}:${aws_db_instance.db[0].password}@tcp(${aws_db_instance.db[0].endpoint})/${aws_db_instance.db[0].name}")))
  depends_on = [data.template_file.test_status]
}

data "template_file" "test_status" {
  template = (var.cluster_type == "etcd" ? "NULL" : ((var.external_db == "postgres" ? aws_db_instance.db[0].endpoint : (var.external_db == "aurora-mysql" ? aws_rds_cluster_instance.db[0].endpoint : aws_db_instance.db[0].endpoint))))
}

data "local_file" "token" {
  filename   = "/tmp/${var.resource_name}_nodetoken"
  depends_on = [aws_instance.master]
}

locals {
  node_token = trimspace("${data.local_file.token.content}")
}

resource "aws_instance" "master2-ha" {
  ami           = var.aws_ami
  instance_type = var.ec2_instance_class
  count         = var.no_of_server_nodes
  connection {
    type        = "ssh"
    user        = var.aws_user
    host        = self.public_ip
    private_key = file(var.access_key)
  }
  root_block_device {
    volume_size = var.volume_size
    volume_type = "standard"
  }
  subnet_id              = var.subnets
  availability_zone      = var.availability_zone
  vpc_security_group_ids = [var.sg_id]
  key_name               = "jenkins-rke-validation"
  depends_on             = [aws_instance.master]
  tags = {
    Name      = "${var.resource_name}-servers"
    yor_trace = "64096210-5f8c-446d-bdf2-fd6c1d013484"
  }
  provisioner "file" {
    source      = "join_k3s_master.sh"
    destination = "/tmp/join_k3s_master.sh"
  }

  provisioner "file" {
    source      = "cis_masterconfig.yaml"
    destination = "/tmp/cis_masterconfig.yaml"
  }
  provisioner "file" {
    source      = "policy.yaml"
    destination = "/tmp/policy.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/join_k3s_master.sh",
      "sudo /tmp/join_k3s_master.sh ${var.node_os} ${aws_route53_record.aws_route53.fqdn} ${var.install_mode} ${var.k3s_version} ${var.cluster_type} ${self.public_ip} ${aws_instance.master.public_ip} ${local.node_token} \"${data.template_file.test.rendered}\" \"${var.server_flags}\" ${var.username} ${var.password}",
    ]
  }
}

resource "aws_lb_target_group" "aws_tg_80" {
  port     = 80
  protocol = "TCP"
  vpc_id   = "${var.vpc_id}"
  name     = "${var.resource_name}-tg-80"
  health_check {
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/ping"
    interval            = 10
    timeout             = 6
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200-399"
  }
  tags = {
    yor_trace = "36c86743-991e-41e5-b7c4-b2ef2cf8a675"
  }
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_80" {
  target_group_arn = "${aws_lb_target_group.aws_tg_80.arn}"
  target_id        = "${aws_instance.master.id}"
  port             = 80
  depends_on       = ["aws_instance.master"]
}


resource "aws_lb_target_group_attachment" "aws_tg_attachment_80_2" {
  target_group_arn = "${aws_lb_target_group.aws_tg_80.arn}"
  count            = length(aws_instance.master2-ha)
  target_id        = "${aws_instance.master2-ha[count.index].id}"
  port             = 80
  depends_on       = ["aws_instance.master"]
}

resource "aws_lb_target_group" "aws_tg_443" {
  port     = 443
  protocol = "TCP"
  vpc_id   = "${var.vpc_id}"
  name     = "${var.resource_name}-tg-443"
  health_check {
    protocol            = "HTTP"
    port                = 80
    path                = "/ping"
    interval            = 10
    timeout             = 6
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200-399"
  }
  tags = {
    yor_trace = "ac8e885e-2f60-425f-b74d-eb0656c47df1"
  }
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_443" {
  target_group_arn = "${aws_lb_target_group.aws_tg_443.arn}"
  target_id        = "${aws_instance.master.id}"
  port             = 443
  depends_on       = ["aws_instance.master"]
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_443_2" {
  target_group_arn = "${aws_lb_target_group.aws_tg_443.arn}"
  count            = length(aws_instance.master2-ha)
  target_id        = "${aws_instance.master2-ha[count.index].id}"
  port             = 443
  depends_on       = ["aws_instance.master"]
}

resource "aws_lb_target_group" "aws_tg_6443" {
  port     = 6443
  protocol = "TCP"
  vpc_id   = "${var.vpc_id}"
  name     = "${var.resource_name}-tg-6443"
  tags = {
    yor_trace = "72a78adb-dbbb-46cc-ab0f-fce54461a776"
  }
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_6443" {
  target_group_arn = "${aws_lb_target_group.aws_tg_6443.arn}"
  target_id        = "${aws_instance.master.id}"
  port             = 6443
  depends_on       = ["aws_instance.master"]
}

resource "aws_lb_target_group_attachment" "aws_tg_attachment_6443_2" {
  target_group_arn = "${aws_lb_target_group.aws_tg_6443.arn}"
  count            = length(aws_instance.master2-ha)
  target_id        = "${aws_instance.master2-ha[count.index].id}"
  port             = 6443
  depends_on       = ["aws_instance.master"]
}

resource "aws_lb" "aws_nlb" {
  internal           = false
  load_balancer_type = "network"
  subnets            = ["${var.subnets}"]
  name               = "${var.resource_name}-nlb"
  tags = {
    yor_trace = "2e13bc7d-182f-496a-938a-26d04a6c8ce5"
  }
}

resource "aws_lb_listener" "aws_nlb_listener_80" {
  load_balancer_arn = "${aws_lb.aws_nlb.arn}"
  port              = "80"
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.aws_tg_80.arn}"
  }
}

resource "aws_lb_listener" "aws_nlb_listener_443" {
  load_balancer_arn = "${aws_lb.aws_nlb.arn}"
  port              = "443"
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.aws_tg_443.arn}"
  }
}

resource "aws_lb_listener" "aws_nlb_listener_6443" {
  load_balancer_arn = "${aws_lb.aws_nlb.arn}"
  port              = "6443"
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.aws_tg_6443.arn}"
  }
}

resource "aws_route53_record" "aws_route53" {
  zone_id    = "${data.aws_route53_zone.selected.zone_id}"
  name       = "${var.resource_name}"
  type       = "CNAME"
  ttl        = "300"
  records    = ["${aws_lb.aws_nlb.dns_name}"]
  depends_on = ["aws_lb_listener.aws_nlb_listener_6443"]
}

data "aws_route53_zone" "selected" {
  name         = "${var.qa_space}"
  private_zone = false
}
