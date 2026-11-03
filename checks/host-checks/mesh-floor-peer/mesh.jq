# A peer below the floor, and one that names no release.
.cluster.mesh.tenants[0].mesh.peers |= (.[2].version = "0.77.3" | .[0].version = "development")
