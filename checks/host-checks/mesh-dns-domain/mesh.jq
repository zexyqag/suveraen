# An account DNS domain, which overrides the mesh's own suffix, and login expiry off.
.cluster.mesh.tenants[0].mesh.settings += {loginExpiry: false, dnsDomain: "mesh.example"}
