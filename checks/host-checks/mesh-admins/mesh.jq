# An admin, a service user and a second owner.
.cluster.mesh.tenants[0].mesh.users |= (
  .[1].role = "admin"
  | .[2].role = "owner"
  | . + [{id: "svc-0001", role: "user", blocked: false, pending: false, service: true, autoGroups: []}])
