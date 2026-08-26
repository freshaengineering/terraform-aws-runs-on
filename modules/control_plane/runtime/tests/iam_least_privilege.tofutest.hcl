mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      dns_suffix = "amazonaws.com"
      partition  = "aws"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/test-stack-runtime"
    }
  }
}

variables {
  region                   = "us-east-1"
  account_id               = "123456789012"
  stack_name               = "test-stack"
  cluster_name             = "test-stack-runtime"
  service_name             = "runs-on"
  task_definition_family   = "test-stack-runtime"
  execution_role_name      = "test-stack-runtime-execution"
  task_role_name           = "test-stack-runtime-task"
  task_policy_name         = "test-stack-runtime-task-policy"
  runner_instance_role_arn = "arn:aws:iam::123456789012:role/test-stack-runner"
  cache_bucket_arn         = "arn:aws:s3:::test-stack-cache"
  log_group_name           = "/runs-on/test-stack/runtime"
  log_retention_days       = 7
  cpu                      = 512
  memory                   = 1024
  desired_count            = 1
  assign_public_ip         = false
  security_group_ids       = ["sg-12345678"]
  subnet_ids               = ["subnet-12345678", "subnet-87654321"]
  tags                     = {}

  container_definitions = [
    {
      name      = "runs-on"
      image     = "example.com/runs-on:latest"
      essential = true
    }
  ]
}

run "delete_fleets_is_never_granted" {
  command = plan

  # The control plane creates instant fleets and tears down capacity with
  # TerminateInstances on specific instance IDs; DeleteFleets would terminate
  # sibling pool jobs sharing the fleet, and AWS reaps instant fleet requests
  # on its own. No code path calls it.
  assert {
    condition = !anytrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      contains(try(statement.Action, []), "ec2:DeleteFleets")
    ])
    error_message = "runtime task role must not grant ec2:DeleteFleets; capacity teardown uses TerminateInstances on specific instances."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      try(statement.Action, []) == ["ec2:CreateFleet"] &&
      statement.Resource == "*"
    ])
    error_message = "runtime task ec2:CreateFleet should stand alone on a wildcard resource; the fleet does not exist at authorization time."
  }
}

run "create_tags_on_shared_infrastructure_requires_tag_on_create" {
  command = plan

  # Tag-on-create plus post-launch pool lease re-tagging, so no CreateAction
  # condition is possible on these resource types.
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      try(statement.Action, []) == ["ec2:CreateTags"] &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:instance/*"), false) &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:volume/*"), false) &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:network-interface/*"), false) &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:spot-instances-request/*"), false) &&
      !can(statement.Condition)
    ])
    error_message = "runtime task should keep unconditioned ec2:CreateTags on runner instances and volumes for pool lease re-tagging."
  }

  # Shared networking and launch infrastructure is never a tag-on-create
  # target, so an unconditioned grant would be an account-wide tag write.
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      try(statement.Action, []) == ["ec2:CreateTags"] &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:subnet/*"), false) &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:security-group/*"), false) &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:launch-template/*"), false) &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:key-pair/*"), false) &&
      try(contains(statement.Condition.StringEquals["ec2:CreateAction"], "RunInstances"), false)
    ])
    error_message = "runtime task ec2:CreateTags on subnets, security groups, launch templates and key pairs should require an ec2:CreateAction tag-on-create context."
  }

  assert {
    condition = !anytrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      contains(try(statement.Action, []), "ec2:CreateTags") &&
      try(contains(statement.Resource, "arn:aws:ec2:us-east-1:123456789012:subnet/*"), false) &&
      !can(statement.Condition)
    ])
    error_message = "runtime task must never grant unconditioned ec2:CreateTags on subnets."
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      try(statement.Action, []) == ["ec2:RunInstances"]
    ])
    error_message = "runtime task ec2:RunInstances should be its own statement, separate from ec2:CreateTags."
  }
}

run "permission_boundary_is_unset_by_default" {
  command = plan

  assert {
    condition     = aws_iam_role.task.permissions_boundary == null
    error_message = "runtime task role should have no permissions boundary when none is configured."
  }

  assert {
    condition     = aws_iam_role.execution.permissions_boundary == null
    error_message = "runtime execution role should have no permissions boundary when none is configured."
  }
}

run "permission_boundary_applies_to_both_roles" {
  command = plan

  variables {
    permission_boundary_arn = "arn:aws:iam::123456789012:policy/test-stack-boundary"
  }

  assert {
    condition     = aws_iam_role.task.permissions_boundary == "arn:aws:iam::123456789012:policy/test-stack-boundary"
    error_message = "runtime task role should carry the configured permissions boundary."
  }

  assert {
    condition     = aws_iam_role.execution.permissions_boundary == "arn:aws:iam::123456789012:policy/test-stack-boundary"
    error_message = "runtime execution role should carry the configured permissions boundary."
  }
}
