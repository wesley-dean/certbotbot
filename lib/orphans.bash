#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/orphans.bash
## @brief Implements explicit desired-lineage pruning in an isolated archive.
## @details
## ADR-059 authorizes bounded deletion of only complete, independently
## classified orphan certificate lineages from one restored, mode-0700 owned
## workspace. The desired set is not inferred from SANs, selected identity,
## existing archive members, or implicit defaults. Complete preflight
## precedes provider action; a selected operation and its unselected-state
## integrity check precede pruning. The existing validated one-key publisher
## is the only remote writer. No host-global Certbot deletion is performed.
##
## No state path in this module comes directly from an unvalidated archive
## string or a shell glob. The expected post-state is a complete, exact
## nonempty set and account state is verified to survive local pruning.

## @var CERTBOTBOT_ORPHANS_TO_REMOVE
## @brief Exact confirmed original archived identities excluded from desired set.
declare -a CERTBOTBOT_ORPHANS_TO_REMOVE=()

## @fn certbotbot_orphans_selected_validate()
## @brief Confirms the explicit selected identity belongs to the desired set.
## @details
## Only a fully valid ordinary selected certificate may anchor a destructive
## reconciliation. This guard runs after the identity resolver and before
## the first external S3 operation.
## @param selected Resolved non-wildcard selected Certbot lineage name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## A fixed nonsecret diagnostic if selection is missing or contradictory.
## @retval 0 Selected identity is an explicitly retained desired member.
## @retval 64 Missing, invalid or contradictory destructive authority.
certbotbot_orphans_selected_validate() {
  local selected="$1" name
  [[ -n "$selected" && "$selected" != *'*'* ]] &&
    certbotbot_dns_valid "$selected" || {
    certbotbot_error 'orphan removal requires a selected certificate'
    return 64
  }
  (( ${#CERTBOTBOT_DESIRED_NAMES[@]} > 0 )) || {
    certbotbot_error 'orphan removal requires an explicit desired set'
    return 64
  }
  for name in "${CERTBOTBOT_DESIRED_NAMES[@]}"; do
    [[ "$name" == "$selected" ]] && return 0
  done
  certbotbot_error 'selected certificate is absent from desired set'
  return 64
}

## @fn certbotbot_orphans_survivors_fingerprint()
## @brief Fingerprints all retained unselected lineages without archive mutation.
## @details
## A stable GNU tar stream includes file content, modes, relative symlinks,
## and historical private-key generations. A selected lineage is deliberately
## omitted because its ordinary provider operation may modify it.
## @param config Restored owned configuration root.
## @param selected Exact selected lineage name to exclude.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One SHA-256 digest, without material or identity exposure.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 Complete digest was calculated.
## @retval 1 Invalid input or absent required tooling.
certbotbot_orphans_survivors_fingerprint() {
  local config="$1" selected="$2" name
  local -a items=()
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  for name in "${CERTBOTBOT_DESIRED_NAMES[@]}"; do
    [[ "$name" == "$selected" ]] && continue
    items+=("renewal/$name.conf" "live/$name" "archive/$name")
  done
  if (( ${#items[@]} == 0 )); then
    sha256sum </dev/null | cut -d' ' -f1
  else
    (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 \
      --numeric-owner --format=gnu -cf - -C "$config" \
      "${items[@]}" 2>/dev/null | sha256sum | cut -d' ' -f1)
  fi
}

## @fn certbotbot_orphans_account_fingerprint()
## @brief Snapshots all existing account material around local pruning only.
## @details
## The selected Certbot action may lawfully update account metadata. This
## function is invoked after that action, and again after local deletion,
## which itself has no authority to mutate any account directory or files.
## @param config Restored owned configuration root.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## SHA-256 digest of sorted account tree including file metadata.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 Existing account tree fingerprinted.
## @retval 1 Missing account directory or required hash tooling.
certbotbot_orphans_account_fingerprint() {
  local config="$1"
  [[ -d "$config/accounts" && ! -L "$config/accounts" ]] || return 1
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 \
    --numeric-owner --format=gnu -cf - -C "$config" accounts \
    2>/dev/null | sha256sum | cut -d' ' -f1)
}

## @fn certbotbot_orphans_plan()
## @brief Establishes immutable authorized prune targets before provider work.
## @details
## Inventories and canonicalizes the complete original state, verifies the
## selected identity and every required nonselected desired identity, then
## treats only original complete lineages absent from the explicit set as
## orphans. All existing leaves and private keys are independently checked
## before destructive authority can proceed. Account-only first issuance is
## allowed when the explicitly selected name is the sole desired identity.
## A malformed or unreadable candidate fails rather than being deleted.
## @param workspace Owned private restored invocation workspace.
## @param config Canonical private Certbot configuration root.
## @param selected Validated exact selected lineage.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nonsecret stage diagnostics, never names or private material.
## @returns Orphans in CERTBOTBOT_ORPHANS_TO_REMOVE.
## @retval 0 All desired members and orphan candidates are unambiguous.
## @retval 65 Missing desired identity or invalid original lineage material.
## @note Lower-level state or OpenSSL statuses may propagate.
certbotbot_orphans_plan() {
  local workspace="$1" config="$2" selected="$3" name found
  local -a sans=()
  local -A original=()
  CERTBOTBOT_ORPHANS_TO_REMOVE=()
  certbotbot_orphans_selected_validate "$selected" || return $?
  certbotbot_state_inventory "$config" "$selected" || return $?
  for name in "${CERTBOTBOT_ARCHIVED_NAMES[@]}"; do
    original["$name"]=1
  done
  for name in "${CERTBOTBOT_DESIRED_NAMES[@]}"; do
    if [[ "$name" != "$selected" && -z "${original[$name]+x}" ]]; then
      printf '%s\n' 'certbotbot: desired archived lineage is absent' >&2
      return 65
    fi
  done
  for name in "${CERTBOTBOT_ARCHIVED_NAMES[@]}"; do
    # Every original lineage must be legitimate, including those excluded.
    certbotbot_renew_sans_read "$config/live/$name/cert.pem" || {
      printf '%s\n' 'certbotbot: unsafe original archived certificate' >&2
      return 65
    }
    sans=("${CERTBOTBOT_EXISTING_SANS[@]}")
    certbotbot_verify_material "$workspace" "$name" "${sans[@]}" ||
      return $?
    found=false
    for wanted in "${CERTBOTBOT_DESIRED_NAMES[@]}"; do
      if [[ "$name" == "$wanted" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" != true ]]; then
      CERTBOTBOT_ORPHANS_TO_REMOVE+=("$name")
    fi
  done
  # The material verifier validates a name at a time. Restore the ordinary
  # selected-lineage classification for issuance or selected renewal.
  certbotbot_state_preflight "$config" "$selected" || return $?
  certbotbot_state_canonical_all "$config" "$selected" || return $?
  return 0
}

## @fn certbotbot_orphans_apply()
## @brief Deletes only confirmed orphan triplets after successful selected work.
## @details
## Receives the immutable plan calculated from the original archive. The
## selected lifecycle has already verified its provider result, all original
## nonselected fingerprints, and the selected certificate. This function
## snapshots retained and account state, checks each deletion boundary
## against the still-canonical complete workspace, removes literal matching
## paths only, and validates the exact requested post-inventory. Any failure
## discards the local candidate and prohibits publication by the caller.
## @param workspace Owned isolated private workspace.
## @param config Canonical private Certbot config root.
## @param selected Exact verified selected certificate lineage name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed stage diagnostics, without certificate identity disclosure.
## @retval 0 Pruned state exactly matches desired members, all valid.
## @retval 65 Unsafe deletion boundary or post-state mutation.
## @retval 74 Local filesystem deletion, fingerprint or verification failed.
certbotbot_orphans_apply() {
  local workspace="$1" config="$2" selected="$3" name root
  local retained_before retained_after account_before account_after
  local -a sans=()
  local -i total=0
  retained_before="$(certbotbot_orphans_survivors_fingerprint \
    "$config" "$selected")" || return 74
  account_before="$(certbotbot_orphans_account_fingerprint "$config")" ||
    return 74
  # All namespaces are private real directories; no symlinked parent may
  # redirect an rm outside the owned workspace.
  for root in renewal live archive; do
    [[ -d "$config/$root" && ! -L "$config/$root" &&
      -O "$config/$root" ]] || {
      printf '%s\n' 'certbotbot: unsafe orphan deletion root' >&2
      return 65
    }
  done
  for name in "${CERTBOTBOT_ORPHANS_TO_REMOVE[@]}"; do
    [[ "$name" != "$selected" && "$name" != *'*'* ]] &&
      certbotbot_dns_valid "$name" || return 65
    certbotbot_state_lineage_one "$config" "$name" || {
      printf '%s\n' 'certbotbot: unsafe orphan deletion target' >&2
      return 65
    }
    [[ -d "$config/live/$name" && ! -L "$config/live/$name" &&
      -O "$config/live/$name" &&
      -d "$config/archive/$name" && ! -L "$config/archive/$name" &&
      -O "$config/archive/$name" &&
      -f "$config/renewal/$name.conf" &&
      ! -L "$config/renewal/$name.conf" ]] || return 65
    if ! rm -f -- "$config/renewal/$name.conf" ||
      ! rm -rf -- "$config/live/$name" "$config/archive/$name"; then
      printf '%s\n' 'certbotbot: scoped orphan deletion failed' >&2
      return 74
    fi
    total=$((total + 1))
  done

  # Verify the exact remaining inventory and ALL survivor material.
  certbotbot_bulk_verify_inventory "$config" "$selected" \
    "${CERTBOTBOT_DESIRED_NAMES[@]}" || return $?
  for name in "${CERTBOTBOT_DESIRED_NAMES[@]}"; do
    if [[ "$name" == "$selected" ]]; then
      sans=("${CERTBOTBOT_SANS[@]}")
    else
      certbotbot_renew_sans_read "$config/live/$name/cert.pem" || return 65
      sans=("${CERTBOTBOT_EXISTING_SANS[@]}")
    fi
    certbotbot_verify_material "$workspace" "$name" "${sans[@]}" ||
      return $?
  done
  retained_after="$(certbotbot_orphans_survivors_fingerprint \
    "$config" "$selected")" || return 74
  account_after="$(certbotbot_orphans_account_fingerprint "$config")" ||
    return 74
  if [[ "$retained_before" != "$retained_after" ||
    "$account_before" != "$account_after" ]]; then
    printf '%s\n' 'certbotbot: orphan pruning altered protected state' >&2
    return 65
  fi
  # Only return the count on successfully verified full reconciliation.
  # shellcheck disable=SC2034
  CERTBOTBOT_ORPHANS_REMOVED="$total"
  return 0
}
