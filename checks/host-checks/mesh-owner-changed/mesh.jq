# The mesh moved to another owner than the one first seen here.
.cluster.mesh.tenants[0].mesh.users |= (.[0].role = "user" | .[1].role = "owner")
