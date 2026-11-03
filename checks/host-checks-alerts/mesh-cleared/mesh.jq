# The exit gone again: it clears, and who can reach what changed with it.
.state.mesh.alpha.access |= (
  .routes = 1
  | .networks["net-home1"].routers += [[null, ["g-home1"]]]
  | .networks["net-home1"].resources += [["res-any", "subnet", true, "91f8675bc4a9dc8c9d4877e798831376"],
      ["res-v6", "subnet", true, "f95625f6ae9c7ce8286ed1b211206764"],
      ["res-name", "domain", true, "891835e479b1600312c720357a51a543"],
      ["res-wide", "subnet", false, "9286d40eec6e1aebe1781917a8ac70c8"]])
