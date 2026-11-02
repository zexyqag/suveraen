# What is wrong with the IDs a tenant's migrations declare, from the ConfigMaps in its Kanidm namespace (suveraen-idm
# check, idm.sh), as a list: each that isn't a UUID in lowercase from Kanidm's dynamic range on, below which Kanidm
# keeps its own entries, and each that more than one declares, of which a later file would change, or turn into its
# own, the entry an earlier one made. All but the platform's founding file's come from the tenant's Secret, whose
# values no check before a release reads.

def valid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
  and . >= "00000000-0000-0000-0001-000000000000";

[.items[] | select(.metadata.name | test("^(kanidm-migrations|sso-[a-z][a-z0-9]*)$"))
  | .metadata.name as $map | .data // {} | to_entries[] | "\($map)/\(.key)" as $file
  | .value | fromjson? | select(type == "object")
  | ., (.assertions | if type == "array" then .[] else empty end)
  | {$file, id: (if type == "object" then .id else null end)}] as $declared
| [($declared[] | select(.id | valid | not)
    | "\(.file): \(.id | tojson | .[:64]) is no UUID in lowercase from 00000000-0000-0000-0001-000000000000 on"),
  ($declared | map(select(.id | valid)) | group_by(.id)[] | select(length > 1)
    | "\(.[0].id) is declared by \(map(.file) | join(", "))")]
| sort
