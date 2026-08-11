# Card 02's enforcement point: compute.trustedImageProjects.
#
# The golden image itself is not a control. Anyone can bake a hardened image and
# then boot something else next to it. The control is the constraint that makes
# every other image un-bootable, and on GCP that constraint operates on the
# image's *project*, not on its name or its labels. There is no tag convention
# to get wrong and no naming rule to work around.
#
# Scoped to the runtime project rather than the organization. At the org it
# would also apply to the build project, where Packer has to boot a stock
# Canonical image in order to harden it, and the build would deadlock on its own
# policy. That collision is the reason the constraint belongs at the boundary
# where images are consumed rather than where they are produced.

resource "google_org_policy_policy" "trusted_images" {
  name   = "projects/${google_project.runtime.project_id}/policies/compute.trustedImageProjects"
  parent = "projects/${google_project.runtime.project_id}"

  spec {
    # No inherit_from_parent. If gcp-landing-zone is standing above this, its
    # own list of trusted image projects would merge in and quietly widen what
    # this project accepts. The point of the demo is a closed list.
    inherit_from_parent = false

    rules {
      values {
        allowed_values = ["projects/${google_project.build.project_id}"]
      }
    }
  }

  depends_on = [google_project_service.runtime]
}

# Cross-project image reads need compute.imageUser on the project that owns the
# image. Two different principals need it and missing either one produces the
# same misleading error: the API reports the image as not found rather than as
# forbidden, because it will not confirm the existence of something the caller
# cannot see.
#
# The Compute service agent needs it to attach the disk.
resource "google_project_iam_member" "runtime_agent_reads_images" {
  project = google_project.build.project_id
  role    = "roles/compute.imageUser"
  member  = "serviceAccount:${local.runtime_agents.compute}"

  depends_on = [time_sleep.runtime_agents]
}

# The caller running the demo needs it to reference the family in the create
# call. An org admin already has it by inheritance, which is exactly why this is
# easy to leave out and then discover from someone else's failed run.
resource "google_project_iam_member" "demo_callers_read_images" {
  for_each = toset(var.image_user_principals)

  project = google_project.build.project_id
  role    = "roles/compute.imageUser"
  member  = each.value
}
