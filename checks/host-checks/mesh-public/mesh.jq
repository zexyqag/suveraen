# The reverse proxy's objects and log, an invite, a proxy peer and Peer Expose.
.cluster.mesh.tenants[0].mesh |= (
  .counts += {proxyTokens: 1, services: 1, targets: 2, domains: 1, proxies: 1, accessLog: 40, invites: 1}
  | .peers[0].embeddedProxy = true
  | .settings.peerExpose = true)
