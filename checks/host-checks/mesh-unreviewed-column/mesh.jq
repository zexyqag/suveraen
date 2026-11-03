# A NetBird release renamed a column the scrub blanks, and added one.
.cluster.mesh.tenants[0].mesh.scrub |= (.gone = ["meta_files"] | .unreviewed = ["meta_file_list", "meta_location"])
