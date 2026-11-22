#!/usr/bin/env bash
# scripts/token-price-ratios.sh - price ratios for one model id (epic E90, story E90_S01, task E90_S01_T02)
#
# Usage: token-price-ratios.sh <model-id>
#
# Reads project/configs/token-price-ratios.json (override: $JENGA_PRICE_RATIOS_FILE) and prints, as one JSON
# object on stdout: {"model","matched","version","date","ratios":{input,cache_write_5m,cache_write_1h,cache_read,output}}.
#
# Model-id matching rule: 1. exact id. 2. if the id ends in "-" plus exactly 8 digits (a date suffix, e.g.
# claude-sonnet-5-5-20261119), strip that suffix and look up the rest exactly. Nothing else: no family, no other
# prefix, no default, no nearby model. "matched" is the config key that was used.
#
# Exit codes: 0 ratios printed; 2 usage error; 3 environment error (jq missing); 4 model has no ratios (stderr:
# "no ratios for <model>", nothing on stdout); 5 config missing or unreadable; 6 config malformed (invalid JSON,
# missing version/date/models, an entry lacking one of the five ratios, a ratio that is not a number >= 0 with at
# most two decimal places).
set -u

CONFIG_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/project/configs/token-price-ratios.json"
CONFIG="${JENGA_PRICE_RATIOS_FILE:-$CONFIG_DEFAULT}"

die() { printf 'token-price-ratios: %s\n' "$2" >&2; exit "$1"; }

if [ "$#" -ne 1 ] || [ -z "$1" ] || [ "${1#-}" != "$1" ]; then die 2 "usage: token-price-ratios.sh <model-id>"; fi
command -v jq >/dev/null 2>&1 || die 3 "jq is required but not found"
if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then die 5 "price-ratio config missing or unreadable: $CONFIG"; fi
jq -e . "$CONFIG" >/dev/null 2>&1 || die 6 "price-ratio config is not valid JSON: $CONFIG"

# Structure check: version and date present, models an object, every entry has the five ratios, each a number
# >= 0 with at most two decimals (x*100 is within 1e-9 of an integer).
jq -e '
  (.config_version | type == "number") and (.date | type == "string" and length > 0)
  and (.models | type == "object")
  and ([.models[] | . as $m
        | all(("input","cache_write_5m","cache_write_1h","cache_read","output");
              . as $k | ($m | type == "object")
                and ($m[$k] | type == "number" and . >= 0 and ((. * 100) - ((. * 100) | round) | fabs) < 1e-9))]
       | all)' "$CONFIG" >/dev/null 2>&1 \
  || die 6 "price-ratio config is malformed (need config_version, date, models; each model with input, cache_write_5m, cache_write_1h, cache_read, output as numbers >= 0 with at most two decimals): $CONFIG"

model="$1"
key=""
if jq -e --arg m "$model" '.models | has($m)' "$CONFIG" >/dev/null; then
  key="$model"
elif [[ "$model" =~ ^(.+)-[0-9]{8}$ ]] && jq -e --arg m "${BASH_REMATCH[1]}" '.models | has($m)' "$CONFIG" >/dev/null; then
  key="${BASH_REMATCH[1]}"
fi
[ -n "$key" ] || die 4 "no ratios for $model"

jq -c --arg model "$model" --arg key "$key" \
  '{model: $model, matched: $key, version: .config_version, date: .date, ratios: .models[$key]}' "$CONFIG"
