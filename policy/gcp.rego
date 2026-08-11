# Repo-local conftest rules, layered on top of the shared suite in
# platform-guardrails.
#
# The shared policies are AWS-shaped by history: access keys, security groups,
# NAT gateways. None of those resource types appear here, so on a GCP repo they
# pass by being vacuously true. These are the GCP equivalents, written against
# the same conftest hcl2 --combine input the shared helpers assume.
#
# Everything here is checkable in the HCL itself. Anything that needs a resolved
# value or has to see inside a module belongs in gcloud beta terraform vet,
# which runs against the plan. See .github/workflows/terraform-vet.yml.

package main

import rego.v1

gcp_blocks_of(v) := v if {
	is_array(v)
}

gcp_blocks_of(v) := [v] if {
	is_object(v)
}

gcp_resources contains r if {
	some file in input
	some type, named in file.contents.resource
	some name, block in named
	some body in gcp_blocks_of(block)
	r := {"type": type, "name": name, "body": body, "path": file.path}
}

# A default VPC arrives with permissive firewall rules nobody chose, in every
# region, and it is created before anyone has a chance to review it.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_project"
	r.body.auto_create_network == true
	msg := sprintf(
		"%s: google_project.%s sets auto_create_network = true. A default VPC is created with rules nobody reviewed.",
		[r.path, r.name],
	)
}

# Legacy ACLs reason about objects one at a time, so a bucket can look locked
# down while a single object in it is readable.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_storage_bucket"
	not r.body.uniform_bucket_level_access
	msg := sprintf(
		"%s: google_storage_bucket.%s does not set uniform_bucket_level_access.",
		[r.path, r.name],
	)
}

# Basic roles carry enough permission to edit the Binary Authorization policy
# and to use the signing key, which collapses the two-project split this repo
# depends on.
basic_roles := {"roles/owner", "roles/editor"}

deny contains msg if {
	some r in gcp_resources
	r.type in {"google_project_iam_member", "google_project_iam_binding"}
	r.body.role in basic_roles
	msg := sprintf(
		"%s: %s.%s grants %s. Basic roles are not granted anywhere in this repo.",
		[r.path, r.type, r.name, r.body.role],
	)
}

# ALWAYS_ALLOW is the setting that makes the policy resource exist while
# enforcing nothing, and it reads as configured to anyone skimming.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_binary_authorization_policy"
	some rule in gcp_blocks_of(r.body.default_admission_rule)
	rule.evaluation_mode == "ALWAYS_ALLOW"
	msg := sprintf(
		"%s: google_binary_authorization_policy.%s admits everything. The policy exists but enforces nothing.",
		[r.path, r.name],
	)
}

# A service account key is a credential that authenticates forever from
# anywhere. This repo federates instead, and the gate exists so that stays true.
deny contains msg if {
	some r in gcp_resources
	r.type == "google_service_account_key"
	msg := sprintf(
		"%s: google_service_account_key.%s creates a long-lived JSON key. Use Workload Identity Federation.",
		[r.path, r.name],
	)
}

# A key with no protection level set inherits SOFTWARE, which is the right
# default here but should be a decision rather than an omission.
warn contains msg if {
	some r in gcp_resources
	r.type == "google_kms_crypto_key"
	some tmpl in gcp_blocks_of(r.body.version_template)
	not tmpl.protection_level
	msg := sprintf(
		"%s: google_kms_crypto_key.%s does not state a protection_level.",
		[r.path, r.name],
	)
}
