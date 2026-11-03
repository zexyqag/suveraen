# The trigger was disabled while two devices wrote what it blanks.
.cluster.mesh.tenants[0].mesh.scrub |= (.trigger.enabled = "D" | .unscrubbed = ["peer-box", "peer-laptop"])
