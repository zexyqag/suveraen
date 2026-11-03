# The camera alice's box routes, in bob's own group: bob's own rule reaches it both ways, over anything, on no port.
.cluster.mesh.tenants[0].mesh |= ((.groups[] | select(.id == "g-own2") | .resources) = [{ID: "res-camera", Type: "host"}])
