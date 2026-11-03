# A device in its home's group and in another's own, a box in another's own, and a person who moved to another's tag.
.cluster.mesh.tenants[0].mesh |= (
  (.groups[] | select(.id == "g-home1") | .peers) += ["peer-laptop"]
  | (.groups[] | select(.id == "g-own2") | .peers) += ["peer-box"]
  | (.groups[] | select(.id == "g-own1") | .peers) += ["peer-phone"]
  | .users[1].autoGroups = ["g-own2"])
