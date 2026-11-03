# The owner switched login expiry off for alice's laptop, and for the box, which joined by a key and never expires.
.cluster.mesh.tenants[0].mesh |= ((.peers[] | select(.id == "peer-laptop" or .id == "peer-box") | .loginExpiry) = false)
