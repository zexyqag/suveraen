# The NetBird release a tenant's mesh runs (kubernetes/apps/netbird), which render holds its images to
# (checks/render.sh). NetBird supports only its latest release.
{
  version = "0.82.0";
  # Index digests at ghcr.io, where NetBird publishes the server images too.
  digests = {
    management = "sha256:07c8f979fcc980678cc64e584cf6b7b27204ceb4c871531b29e2dce39592e9ff";
    signal = "sha256:0c0c38bbef7dcdfa1822b6d59844615db55dc7303b664e7aed498151edc0dbfb";
    relay = "sha256:8f6b9e4193653ede89e83dd4aa4e2cf2562579b3e2481dcf259a7ab28bcd5fa1";
  };
  # Its newest release at each bump, as NetBird's own installer pairs them; published at Docker Hub alone.
  dashboard = {
    tag = "v2.96.0-rootless";
    digest = "sha256:0f0097965c36bd4702eae6cdb007d6398ea7783f3d395942c909c7fb55a827d4";
  };
}
