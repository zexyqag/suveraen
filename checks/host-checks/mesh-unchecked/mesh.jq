# The mesh's query failed, as after a NetBird bump that moved a column, and has for longer than the limit.
.cluster.mesh.tenants = [{tenant: "alpha",
  unchecked: "psql:<stdin>:77: ERROR:  column \"settings_peer_expose_enabled\" does not exist"}]
| .state.mesh.alpha.uncheckedSince = 1792667700
