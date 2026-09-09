def event($code; $chainName; $stepIndex; $field; $value):
  [$code, $chainName, $stepIndex, $field, $value]
  | map(if . == null or . == "" then "-" else tostring end)
  | @tsv;
def has_value:
  if . == null then false else (tostring | length > 0) end;
def known_agent:
  . == "codex" or . == "claude" or . == "agy";
def known_window:
  . == "5h" or . == "weekly";
def valid_integer($minimum; $maximum):
  if type != "number" then false
  else . >= $minimum and . <= $maximum and floor == .
  end;
def valid_notice:
  .usageLimits.notice as $notice
  | if ($notice | type) != "object" then false
    elif (($notice.enabled | type) != "boolean") then false
    else ($notice.intervalSeconds | valid_integer(1; 604800))
    end;
def usage_result:
  if (has("usageLimits") | not) then
    {valid: true, events: []}
  elif (.usageLimits | type) != "object" then
    {valid: false, events: [event("usage_object"; ""; ""; ""; "")]}
  elif ((.usageLimits.liveProviders // []) | type) != "array" then
    {valid: false, events: [event("usage_live_providers_array"; ""; ""; ""; "")]}
  else
    (first(.usageLimits.liveProviders[] | select((known_agent | not))) // null) as $badProvider
    | if $badProvider != null then
        {valid: false, events: [event("usage_provider"; ""; ""; ""; $badProvider)]}
      else
        (first(["cacheTtlSeconds", "timeoutSeconds"][] as $field
          | select((.usageLimits[$field] // 0 | valid_integer(1; 3600) | not))
          | $field) // null) as $badField
        | if $badField != null then
            {valid: false, events: [event("usage_integer"; ""; ""; $badField; "")]}
          elif (.usageLimits | has("notice")) and (valid_notice | not) then
            {valid: false, events: [event("usage_notice"; ""; ""; ""; "")]}
          else
            {valid: true, events: []}
          end
      end
  end;
def valid_chain_name:
  type == "string" and length > 0 and test("^[A-Za-z0-9._-]+$");
def selector_result($chainName; $selector):
  if ($selector | type) != "object" or ($selector | length) == 0 then
    {stop: true, events: [event("selector_object"; $chainName; ""; ""; "")]}
  else
    (first($selector | keys_unsorted[] | select(. as $key
      | (($selector[$key] | ["parentAgent", "parentModel", "parentEffort"] | index(.)) == null))) // null) as $badField
    | if $badField != null then
        {stop: true, events: [event("selector_field"; $chainName; ""; $badField; "")]}
      else
        (first($selector | keys_unsorted[] | . as $key
          | select(($selector[$key] | has_value) | not) | $key) // null) as $emptyField
        | if $emptyField != null then
            {stop: true, events: [event("selector_empty"; $chainName; ""; $emptyField; "")]}
          elif ($selector | has("parentAgent")) and (($selector.parentAgent | known_agent) | not) then
            {stop: true, events: [event("selector_agent"; $chainName; ""; "parentAgent"; $selector.parentAgent)]}
          else
            {stop: false, events: []}
          end
      end
  end;
def embedded_events($chainName; $stepIndex; $agent):
  ([(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"][] as $level
    | [$registry.models[]
      | select(.agent == $agent and .reasoning.separateAxis == false
        and ((.reasoning.levels // []) | index($level) != null))
      | .model] as $ids
    | if ($ids | length) == 0 then empty
      else [event("embedded_level"; $chainName; $stepIndex; $level; $level)]
        + ($ids | map(event("embedded_id"; $chainName; $stepIndex; $level; .)))
      end)] | add // []);
def reasoning_result($chainName; $stepIndex; $agent; $model; $entry; $hasEffort; $effort):
  if ($entry.reasoning.separateAxis == false) then
    if $hasEffort then
      {fatal: true,
        events: ([event("embedded_header"; $chainName; $stepIndex; $agent; $model)]
          + embedded_events($chainName; $stepIndex; $agent))}
    else
      {fatal: false, events: []}
    end
  elif (($effort | has_value) | not) then
    {fatal: true, events: [event("missing_effort"; $chainName; $stepIndex; $agent; $model)]}
  else
    ([$entry.reasoning.levels[]?]) as $levels
    | if any($levels[]; . == $effort) then
        {fatal: false, events: []}
      else
        {fatal: true,
          events: ([event("bad_effort_header"; $agent; $model; $effort; "-")]
            + (if ($levels | length) == 0 then
                [event("bad_effort_none"; $chainName; $stepIndex; ""; "")]
              else
                ($levels | map(event("bad_effort_level"; $chainName; $stepIndex; ""; .)))
              end))}
      end
  end;
def model_result($chainName; $stepIndex; $agent; $model; $hasEffort; $effort; $unvalidated):
  if $unvalidated then
    {fatal: false, events: []}
  else
    (first($registry.models[] | select(.agent == $agent and .model == $model)) // null) as $entry
    | if $entry == null then
        {fatal: $strict,
          events: ([event("unknown_model"; $chainName; $stepIndex; $agent; $model)]
            + ([$registry.models[] | select(.agent == $agent) | .model
                | event("unknown_model_id"; $chainName; $stepIndex; ""; .)])
            + [if $strict then
                 event("invalid_unknown_model"; $chainName; $stepIndex; $agent; $model)
               else
                 event("migration_required"; $chainName; $stepIndex; $agent; $model)
               end])}
      else
        ($entry.status // "active") as $status
        | ([if $status == "retired" or $status == "deprecated" then
              event("lifecycle"; $agent; $model; $status; ($entry.retirementDate // ""))
            else empty end]) as $lifecycle
        | reasoning_result($chainName; $stepIndex; $agent; $model; $entry; $hasEffort; $effort) as $reasoning
        | {fatal: $reasoning.fatal, events: ($lifecycle + $reasoning.events)}
      end
  end;
def until_events($chainName; $stepIndex; $step):
  if ($step | has("until")) then
    ($step.until) as $until
    | if ($until | type) != "object"
        or (($until | keys | sort) != ["usedPercent", "window"]) then
        [event("until_object"; $chainName; $stepIndex; ""; "")]
      elif (($until.usedPercent | valid_integer(0; 100))
            and (($until.usedPercent | type) == "number")) | not then
        [event("until_used_percent"; $chainName; $stepIndex; ""; "")]
      elif (($until.window | known_window) | not) then
        [event("until_window"; $chainName; $stepIndex; ""; $until.window)]
      else []
      end
  else []
  end;
def step_result($chainName; $stepIndex; $step):
  if ($step | type) != "object" then
    {fatal: true, events: [event("step_object"; $chainName; $stepIndex; ""; "")]}
  else
    (first($step | keys_unsorted[] | select(. as $key
      | (["agent", "model", "effort", "until", "unvalidated"] | index($key)) == null)) // null) as $badField
    | if $badField != null then
        {fatal: true, events: [event("step_field"; $chainName; $stepIndex; $badField; "")]}
      else
        ($step.agent // null) as $agent
        | ($step.model // null) as $model
        | ($step.effort // null) as $effort
        | (($step | has("effort"))) as $hasEffort
        | (($step.unvalidated // false) == true) as $unvalidated
        | if ($agent | has_value) | not then
            {fatal: true, events: [event("agent_required"; $chainName; $stepIndex; ""; "")]}
          elif ($agent | known_agent) | not then
            {fatal: true, events: [event("agent_unknown"; $chainName; $stepIndex; ""; $agent)]}
          elif ($model | has_value) | not then
            {fatal: true, events: [event("model_required"; $chainName; $stepIndex; ""; "")]}
          else
            model_result($chainName; $stepIndex; $agent; $model; $hasEffort; $effort; $unvalidated) as $modelCheck
            | if $modelCheck.fatal then
                $modelCheck
              else
                {fatal: false,
                  events: ($modelCheck.events
                    + until_events($chainName; $stepIndex; $step))}
              end
          end
      end
  end;
def chain_result($config; $chainName):
  $config.chains[$chainName] as $chainEntry
  | if ($chainName | valid_chain_name) | not then
      {stop: true, events: [event("chain_name"; ""; ""; ""; $chainName)]}
    else
      (($chainEntry.when // null) as $selector
        | selector_result($chainName; $selector)) as $selectorCheck
      | if $selectorCheck.stop then $selectorCheck
        else
          ($chainEntry.steps // null) as $steps
          | if ($steps | type) != "array" or ($steps | length) == 0 then
              {stop: true, events: [event("steps_empty"; $chainName; ""; ""; "")]}
            else
              (reduce ($steps | to_entries[]) as $stepEntry
                ({stop: false, events: []};
                  (step_result($chainName; ($stepEntry.key + 1); $stepEntry.value)) as $stepCheck
                  | .events += $stepCheck.events)) as $stepChecks
              | {stop: false, events: $stepChecks.events}
            end
        end
    end;
 . as $config
| if (type != "object"
    or (.chains | type) != "object"
    or (.defaultSteps | type) != "array") then
  [event("config_shape"; ""; ""; ""; "")]
else
  usage_result as $usage
  | if ($usage.valid | not) then
      $usage.events
    else
      (first((.chains | keys[]) | select((valid_chain_name) | not)) // null) as $badName
      | if $badName != null then
          [event("chain_name"; ""; ""; ""; $badName)]
        else
          (reduce (.chains | keys[]) as $chainName
            ({stop: false, events: []};
              if .stop then .
              else
                    (chain_result($config; $chainName)) as $chainCheck
                | .events += $chainCheck.events
                | if $chainCheck.stop then .stop = true else . end
              end)) as $chainsCheck
          | if $chainsCheck.stop then
              $chainsCheck.events
            else
              ($chainsCheck.events + (reduce ($config.defaultSteps | to_entries[]) as $stepEntry
                ({events: []};
                  (step_result("default"; ($stepEntry.key + 1); $stepEntry.value)) as $stepCheck
                  | .events += $stepCheck.events)).events)
            end
        end
    end
end
| .[]
