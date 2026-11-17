# What is wrong with the IDs a tenant's migrations declare, from the ConfigMaps in its Kanidm namespace (suveraen-idm
# check, idm.sh), as a list: each that isn't a UUID in lowercase from Kanidm's dynamic range on, below which Kanidm
# keeps its own entries, and each that the files declare other than as one file's own, as an entry one file makes and
# one changes, or as an entry one removes: Kanidm would then refuse every file, change or keep the wrong entry, or make
# none. All but the platform's founding files' come from the tenant's Secret, whose values no check before a release
# reads.

def valid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
  and . >= "00000000-0000-0000-0001-000000000000";

[.items[] | select(.metadata.name | test("^(kanidm-migrations|sso-[a-z][a-z0-9]*)$"))
  | .metadata.name as $map | .data // {} | to_entries[] | "\($map)/\(.key)" as $file
  | .value | fromjson? | select(type == "object")
  | {$file, id, role: "file"},
    (.assertions | if type == "array" then .[] else empty end
     | {$file, id: (if type == "object" then .id else null end),
        role: (if type != "object" then "?" elif .state == "absent" then "removes" elif has("class") then "makes"
               else "changes" end)})] as $declared
| [($declared[] | select(.id | valid | not)
    | "\(.file): \(.id | tojson | .[:64]) is no UUID in lowercase from 00000000-0000-0000-0001-000000000000 on"),
  ($declared | map(select(.id | valid)) | group_by(.id)[]
    | select(map(.role) | sort | IN(["file"], ["changes", "makes"], ["removes"]) | not)
    | "\(.[0].id) is declared by \(map("\(.file) (\(.role))") | join(", "))")]
| sort
