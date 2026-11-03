# Policies whose version check is older than the floor or missing, and a disabled one without, which counts for
# nothing.
.cluster.mesh.tenants[0].mesh |= (
  .postureChecks += [{id: "pc-old", checks: {NBVersionCheck: {MinVersion: "0.71.4"}}}]
  | (.policies[] | select(.id == "pol-own2") | .postureChecks) = ["pc-old"]
  | (.policies[] | select(.id == "pol-share") | .postureChecks) = []
  | .policies += [.policies[0] | .id = "pol-off" | .enabled = false | .postureChecks = [] | .rules[0].id = "pol-off"])
