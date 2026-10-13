#!/bin/bash
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: scripts/reauthorize.sh [--dry-run]

Update Keyvault login-Keychain partition lists for the installed app and CLI.
The real operation prompts once for the login-Keychain password in a terminal.
USAGE
}

dry_run=false
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=true ;;
  --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if [[ "$#" -gt 1 ]]; then
  usage >&2
  exit 2
fi
if [[ "$dry_run" == false && ! -t 0 ]]; then
  echo "Run scripts/reauthorize.sh from a terminal so security can prompt for the login-Keychain password." >&2
  exit 2
fi

home="$HOME"
keychain_path="$home/Library/Keychains/login.keychain-db"
application_path="$home/Applications/Keyvault.app"
cli_path="$application_path/Contents/MacOS/kv"
service_name="com.firstmate.keyvault"

read_cdhash() {
  local binary_path="$1"
  local details
  local cdhash

  details="$(/usr/bin/codesign -dvvv "$binary_path" 2>&1)"
  cdhash="$(printf '%s\n' "$details" | /usr/bin/awk -F= '/^CDHash=/ { print tolower($2); exit }')"
  if [[ ! "$cdhash" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Could not read a valid CDHash from $binary_path." >&2
    return 1
  fi
  printf '%s\n' "$cdhash"
}

app_cdhash="$(read_cdhash "$application_path")"
cli_cdhash="$(read_cdhash "$cli_path")"
if [[ ! -f "$keychain_path" ]]; then
  echo "Login Keychain not found: $keychain_path" >&2
  exit 1
fi

temporary_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/keyvault-reauthorize.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
dump_path="$temporary_directory/keychain.dump"
observations_path="$temporary_directory/observations.tsv"
partition_path="$temporary_directory/partition-list"

dump_metadata() {
  # -a reads item attributes and access metadata; do not add -d, which dumps data.
  /usr/bin/security dump-keychain -a "$keychain_path" > "$1"
}

extract_observations() {
  /usr/bin/awk -v service_name="$service_name" -v app_cdhash="$app_cdhash" -v cli_cdhash="$cli_cdhash" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    function flush_item(    entry, normalized_hash) {
      if (record_generic && record_service) {
        matching_items++
        app_found = 0
        cli_found = 0
        for (entry in item_entries) {
          if (tolower(substr(entry, 1, 7)) == "cdhash:") {
            normalized_hash = tolower(substr(entry, 8))
            if (normalized_hash == app_cdhash) app_found = 1
            if (normalized_hash == cli_cdhash) cli_found = 1
          } else {
            printf "E\t%s\n", entry
          }
        }
        if (app_found && cli_found) print "V\t1"
        else print "V\t0"
      }
      for (entry in item_entries) delete item_entries[entry]
      record_generic = 0
      record_service = 0
      partition_pending = 0
    }
    {
      if ($0 ~ /^keychain:/) {
        flush_item()
        next
      }
      if ($0 ~ /^class:[[:space:]]*"genp"/) record_generic = 1

      marker = "\"svce\"<blob>=\""
      marker_position = index($0, marker)
      if (marker_position > 0) {
        service_value = substr($0, marker_position + length(marker))
        quote_position = index(service_value, "\"")
        if (quote_position > 0 && substr(service_value, 1, quote_position - 1) == service_name) {
          record_service = 1
        }
      }

      if (index($0, "authorizations") > 0 && index($0, "partition_id") > 0) {
        partition_pending = 1
        next
      }
      if (partition_pending && index($0, "description:") > 0) {
        description_position = index($0, "description:")
        description = trim(substr($0, description_position + length("description:")))
        if (substr(description, 1, 1) == "\"" && substr(description, length(description), 1) == "\"") {
          description = substr(description, 2, length(description) - 2)
        }
        entry_count = split(description, parsed_entries, ",")
        for (entry_index = 1; entry_index <= entry_count; entry_index++) {
          entry = trim(parsed_entries[entry_index])
          if (entry != "") item_entries[entry] = 1
        }
        partition_pending = 0
        next
      }
      if (partition_pending && index($0, "authorizations") > 0) partition_pending = 0
    }
    END {
      flush_item()
      printf "COUNT\t%d\n", matching_items
    }
  ' "$1" > "$2"
}

show_plan() {
  local observations="$1"
  local partition_output="$2"
  local matching_items
  local entry_counts
  local common_entries=""
  local entries_differ=false
  local entry
  local count
  local partition_list="cdhash:$app_cdhash,cdhash:$cli_cdhash"

  matching_items="$(/usr/bin/awk -F '\t' '$1 == "COUNT" { print $2 }' "$observations")"
  if [[ ! "$matching_items" =~ ^[0-9]+$ || "$matching_items" -eq 0 ]]; then
    echo "No matching generic-password items found for $service_name." >&2
    return 1
  fi

  entry_counts="$(/usr/bin/awk -F '\t' '$1 == "E" { counts[$2]++ } END { for (entry in counts) print entry "\t" counts[entry] }' "$observations" | LC_ALL=C /usr/bin/sort)"
  if [[ -n "$entry_counts" ]]; then
    while IFS=$'\t' read -r entry count; do
      [[ -n "$entry" ]] || continue
      if [[ "$count" == "$matching_items" ]]; then
        if [[ -z "$common_entries" ]]; then common_entries="$entry"
        else common_entries="$common_entries,$entry"
        fi
      else
        entries_differ=true
      fi
    done <<< "$entry_counts"
  fi

  if [[ "$entries_differ" == true ]]; then
    echo "Non-CDHash partition entries differ across items; only entries common to all items are kept."
  fi
  if [[ -n "$common_entries" ]]; then partition_list="$partition_list,$common_entries"; fi

  if [[ "$dry_run" == true ]]; then
    printf 'Would set partition list %s on %s matching item(s).\n' "$partition_list" "$matching_items"
  else
    printf 'Will set partition list %s on %s matching item(s).\n' "$partition_list" "$matching_items"
  fi
  printf 'Distinct non-CDHash partition entries and item counts:\n'
  if [[ -n "$entry_counts" ]]; then
    while IFS=$'\t' read -r entry count; do
      [[ -n "$entry" ]] || continue
      printf '  %s: %s\n' "$entry" "$count"
    done <<< "$entry_counts"
  fi
  printf '%s\n' "$partition_list" > "$partition_output"
}

dump_metadata "$dump_path"
extract_observations "$dump_path" "$observations_path"
show_plan "$observations_path" "$partition_path"
partition_list="$(/bin/cat "$partition_path")"

if [[ "$dry_run" == true ]]; then
  echo "Dry run: security set-generic-password-partition-list call skipped."
  exit 0
fi

/usr/bin/security set-generic-password-partition-list \
  -s "$service_name" \
  -S "$partition_list" \
  "$keychain_path"

dump_metadata "$dump_path"
extract_observations "$dump_path" "$observations_path"
matching_items="$(/usr/bin/awk -F '\t' '$1 == "COUNT" { print $2 }' "$observations_path")"
verified_items="$(/usr/bin/awk -F '\t' '$1 == "V" && $2 == "1" { count++ } END { print count + 0 }' "$observations_path")"
printf 'Verified current app and CLI partition entries on %s of %s matching item(s).\n' "$verified_items" "$matching_items"
if [[ "$matching_items" -eq 0 || "$verified_items" -ne "$matching_items" ]]; then
  echo "Partition-list verification failed." >&2
  exit 1
fi
