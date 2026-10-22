# The two providers that keep the off-site copies, as stand-ins on a test's internet node: a versitygw for each, at an
# address of its own. Each is as it is at onboarding: each of the cluster's tenants' buckets locked, and a key for each
# of the tenant's apps with copies there, which may list and write under the app's own prefix alone: postgres/, whose
# copies it never deletes, or volsync/<app>/, where restic deletes what it prunes but never the repository's config or
# keys. None of them unlocks a copy, which outlives any delete for as long as it is locked. The root keys are the
# provider's own, test stand-ins.
{
  # The cluster's directory: its settings name the buckets, and its tenants' secrets the apps' keys.
  cluster,
  # Provider n's address, which the node takes on eth1.
  address,
  port,
}:
{ lib, pkgs, ... }:
let
  providers = [
    1
    2
  ];
in
{
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
  networking.interfaces.eth1.ipv4.addresses = lib.mkAfter (
    map (n: {
      address = address n;
      prefixLength = 24;
    }) providers
  );
  environment.systemPackages = [ pkgs.awscli2 ];
  systemd.services = lib.listToAttrs (
    lib.concatMap (
      n:
      let
        name = "s3-${toString n}";
        endpoint = "http://${address n}:${toString port}";
        root = "--access root-${toString n} --secret root-${toString n}-test-secret";
        setup = pkgs.writeShellApplication {
          name = "${name}-setup";
          runtimeInputs = [
            pkgs.awscli2
            pkgs.versitygw
            pkgs.yq-go
            pkgs.jq
            pkgs.curl
          ];
          text = ''
            export AWS_ACCESS_KEY_ID=root-${toString n} AWS_SECRET_ACCESS_KEY=root-${toString n}-test-secret
            export AWS_DEFAULT_REGION=us-east-1 AWS_ENDPOINT_URL=${endpoint} HOME=$RUNTIME_DIRECTORY
            until curl -s -o /dev/null ${endpoint}; do sleep 1; done
            prefix=$(yq .data.BACKUP_${toString n}_BUCKET_PREFIX ${cluster}/settings.yaml)
            for secrets in ${cluster}/tenants/*/secrets.yaml; do
              bucket=$prefix$(basename "$(dirname "$secrets")")
              aws s3api create-bucket --bucket "$bucket" --object-lock-enabled-for-bucket
              aws s3api put-object-lock-configuration --bucket "$bucket" --object-lock-configuration \
                '{"ObjectLockEnabled": "Enabled", "Rule": {"DefaultRetention": {"Mode": "COMPLIANCE", "Days": 1}}}'
              statements=()
              for app in $(yq '.stringData | keys | .[] | select(test("_BACKUP_${toString n}_ACCESS_KEY_ID$"))
                | sub("_BACKUP_.*", "")' "$secrets"); do
                key=$(yq ".stringData.''${app}_BACKUP_${toString n}_ACCESS_KEY_ID" "$secrets")
                versitygw admin ${root} --endpoint-url ${endpoint} create-user --role user --access "$key" \
                  --secret "$(yq ".stringData.''${app}_BACKUP_${toString n}_SECRET_ACCESS_KEY" "$secrets")"
                if [ "$app" = POSTGRES ]; then
                  path=postgres/ actions='["s3:GetObject", "s3:PutObject", "s3:PutObjectRetention"]' pruned='[]'
                else
                  path=volsync/''${app,,}/ actions='["s3:GetObject", "s3:PutObject"]'
                  pruned='["data/", "index/", "snapshots/", "locks/"]'
                fi
                statements+=("$(jq -cn --arg key "$key" --arg bucket "$bucket" --arg path "$path" \
                  --argjson actions "$actions" --argjson pruned "$pruned" '[
                    {Effect: "Allow", Principal: {AWS: [$key]}, Action: ["s3:ListBucket"],
                      Resource: ["arn:aws:s3:::\($bucket)"], Condition: {StringLike: {"s3:prefix": ["\($path)*"]}}},
                    {Effect: "Allow", Principal: {AWS: [$key]}, Action: $actions,
                      Resource: ["arn:aws:s3:::\($bucket)/\($path)*"]}]
                    + if $pruned == [] then [] else [{Effect: "Allow", Principal: {AWS: [$key]},
                      Action: ["s3:DeleteObject"], Resource: [$pruned[] | "arn:aws:s3:::\($bucket)/\($path)\(.)*"]}] end')")
              done
              aws s3api put-bucket-policy --bucket "$bucket" \
                --policy "$(printf '%s\n' "''${statements[@]}" | jq -cs '{Version: "2012-10-17", Statement: add}')"
            done
          '';
        };
      in
      [
        (lib.nameValuePair name {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            StateDirectory = map (dir: "${name}/${dir}") [
              "data"
              "versions"
              "iam"
            ];
            ExecStart =
              "${pkgs.versitygw}/bin/versitygw --port ${address n}:${toString port} ${root} --iam-dir /var/lib/${name}/iam"
              + " posix --versioning-dir /var/lib/${name}/versions /var/lib/${name}/data";
          };
        })
        (lib.nameValuePair "${name}-setup" {
          wantedBy = [ "multi-user.target" ];
          requires = [ "${name}.service" ];
          after = [ "${name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            RuntimeDirectory = "${name}-setup";
            ExecStart = lib.getExe setup;
          };
        })
      ]
    ) providers
  );
  networking.firewall.allowedTCPPorts = [ port ];
}
