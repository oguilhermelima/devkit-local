def value_or_dash($entry; $key):
  if ($entry | has($key))
    and ($entry[$key] != null)
    and ($entry[$key] != false) then
    ($entry[$key] | tostring)
  else
    "-"
  end;

.chains
| to_entries[]
| .value as $chainEntry
| [
    .key,
    value_or_dash($chainEntry.when; "parentAgent"),
    value_or_dash($chainEntry.when; "parentModel"),
    value_or_dash($chainEntry.when; "parentEffort"),
    ($chainEntry.steps | tojson)
  ]
| @tsv
