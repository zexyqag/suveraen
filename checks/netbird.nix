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
  # What the e2e upgrades from: what the last signed release runs, or before any release ran a mesh, the newest
  # release of the minor before.
  previous = {
    version = "0.81.5";
    digests = {
      management = "sha256:1b8c177dce855ef83e4da0fcd82a51a78b80145eb48453fe363fd40aca4b5471";
      signal = "sha256:eea5dfeb5ad81216731a7c53b2a2b5b5a35115e66327bbd42c3704fc0b9a857e";
      relay = "sha256:9e2b250ed5bfb63c98fb2d184b59847facc200876211ce54bebc86b50499537f";
    };
  };
  # The e2e's members' devices run NetBird's own Linux client, by the hash of its release tarball: this release, and
  # the oldest one a mesh takes (suveraen.checks.mesh.minimumClient), which every policy's version check names.
  clients = {
    "0.82.0" = "sha256-tWn2XeMD0hMXvHFvMRYALizxda4iqfbSvtkSAKL1AAs=";
    "0.78.0" = "sha256-kr3Nd8trVsdqn2kV4xXe1Bt4K2S+7UUdGqDk/wmNWrk=";
  };
}
