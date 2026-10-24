#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/state.bash
## @brief Verifies local ACME account presence and selected-lineage coherence.
## @details
## This module enforces the read-only preflight contract in ADR-023.
## Archive format verification and safe extraction must already have completed.
## No restored scripts or configuration are executed or sourced. The checks
## deliberately do not claim that the account is registered remotely or that
## canonical renewal metadata has been mapped into a private Certbot runtime.

## @fn certbotbot_state_account()
## @brief Requires one unambiguous production ACME account with private files.
## @details
## The account must occupy Certbot's production endpoint directory and contain
## nonempty, regular registration, key and metadata files. No other account
## endpoints or competing IDs are allowed in the single-account MVP. The key
## must have no group/other permissions. Content is never printed or parsed.
## @param config Canonical private restored Certbot configuration root.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 One local account has the required expected structure.
## @retval 1 Account selection or on-disk structure is unsuitable.
certbotbot_state_account() {
  local config="$1" host directory account entry file count=0
  host="$config/accounts/acme-v02.api.letsencrypt.org"
  directory="$host/directory"
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] ||
    return 1
  for entry in "$config/accounts/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$host" && -d "$entry" && ! -L "$entry" ]] ||
      return 1
  done
  for entry in "$host/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "$directory" && -d "$entry" && ! -L "$entry" ]] ||
      return 1
  done
  for entry in "$directory/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ -d "$entry" && ! -L "$entry" && -O "$entry" ]] || return 1
    count=$((count + 1))
    (( count == 1 )) || return 1
    account="$entry"
  done
  (( count == 1 )) || return 1
  for file in private_key.json regr.json meta.json; do
    entry="$account/$file"
    [[ -f "$entry" && ! -L "$entry" && -s "$entry" &&
      -r "$entry" && -O "$entry" ]] || return 1
    if [[ "$file" == private_key.json ]]; then
      [[ -z "$(find "$entry" -perm /077 -print -quit 2>/dev/null)" ]] ||
        return 1
    else
      [[ -z "$(find "$entry" -perm /022 -print -quit 2>/dev/null)" ]] ||
        return 1
    fi
  done
  for entry in "$account/"*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    case "${entry##*/}" in
      private_key.json|regr.json|meta.json) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

## @fn certbotbot_state_hooks()
## @brief Rejects archived hook configuration and executable hook directories.
## @details
## Archived hook command execution is excluded from the MVP. A cli.ini file
## can inject arbitrary Certbot options and is therefore refused. Empty
## renewal-hooks directories may exist, but no non-directory members are
## allowed. A later version may add reviewed compatibility for specific
## inert options; this version fails closed.
## @param config Canonical private restored configuration root.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 No disallowed global hook options or scripts were found.
## @retval 1 Unexpected hook content or unsafe configuration was found.
certbotbot_state_hooks() {
  local config="$1" bad
  [[ ! -e "$config/cli.ini" && ! -L "$config/cli.ini" ]] || return 1
  if [[ -e "$config/renewal-hooks" || -L "$config/renewal-hooks" ]]; then
    [[ -d "$config/renewal-hooks" &&
      ! -L "$config/renewal-hooks" ]] || return 1
    bad="$(find "$config/renewal-hooks" -mindepth 1 ! -type d \
      -print -quit 2>/dev/null)" || return 1
    [[ -z "$bad" ]] || return 1
  fi
}

## @fn certbotbot_state_lineage_one()
## @brief Verifies one complete lineage's relative links and local member types.
## @details
## The caller has inventoried all top-level renewal/live/archive names.
## This read-only check never uses contents of archived renewal configuration
## as shell code. Every live link must target its own matching archive
## subtree, not another certificate's versioned PEM or an absolute path.
## @param config Private restored configuration root.
## @param name Validated non-wildcard Certbot lineage name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @retval 0 Complete and safe supported lineage structure.
## @retval 1 Partial or unsafe files, links, hooks or member types.
certbotbot_state_lineage_one() {
  local config="$1" name="$2" part path member target
  [[ -d "$config/live/$name" && ! -L "$config/live/$name" &&
    -d "$config/archive/$name" && ! -L "$config/archive/$name" &&
    -f "$config/renewal/$name.conf" &&
    ! -L "$config/renewal/$name.conf" &&
    -s "$config/renewal/$name.conf" &&
    -O "$config/renewal/$name.conf" ]] || return 1
  if LC_ALL=C grep -qi 'hook' "$config/renewal/$name.conf"; then
    return 1
  fi
  for part in cert chain fullchain privkey; do
    path="$config/live/$name/$part.pem"
    [[ -L "$path" ]] || return 1
    target="$(readlink -- "$path")" || return 1
    certbotbot_tar_link "live/$name/$part.pem" "$target" || return 1
    [[ -f "$config/$REPLY" && ! -L "$config/$REPLY" ]] || return 1
  done
  for member in "$config/live/$name/"* "$config/live/$name/".*; do
    [[ -e "$member" || -L "$member" ]] || continue
    case "${member##*/}" in
      .|..) continue ;;
      README) [[ -f "$member" && ! -L "$member" ]] || return 1 ;;
      cert.pem|chain.pem|fullchain.pem|privkey.pem)
        [[ -L "$member" ]] || return 1 ;;
      *) return 1 ;;
    esac
  done
  for member in "$config/archive/$name/"* "$config/archive/$name/".*; do
    [[ -e "$member" || -L "$member" ]] || continue
    case "${member##*/}" in .|..) continue ;; esac
    if [[ "${member##*/}" != README ]]; then
      [[ "${member##*/}" =~ ^(cert|chain|fullchain|privkey)[1-9][0-9]*\.pem$ ]] ||
        return 1
    fi
    [[ -f "$member" && ! -L "$member" && -O "$member" ]] || return 1
    if [[ "${member##*/}" == privkey[0-9]*.pem &&
      -n "$(find "$member" -perm /077 -print -quit 2>/dev/null)" ]]; then
      return 1
    fi
  done
  return 0
}

## @fn certbotbot_state_lineage()
## @brief Inventories every valid lineage and classifies one selected target.
## @details
## An account-only archive may omit all lineage trees. All non-README members
## in renewal/, live/ and archive/ must have complete matching triplets.
## Every name is validated separately, so an unrelated existing certificate
## cannot be silently dropped or chosen by SAN overlap. This read-only check
## validates the local structure of every stored lineage and reports whether
## the exact selected lineage is present or absent; canonical renewal metadata
## is separately verified using certbotbot_state_canonical_all.
## @param config Private restored configuration root.
## @param selected Validated non-wildcard certificate name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT; selected status is stored in REPLY.
## @retval 0 Every stored lineage is complete; selected is absent or present.
## @retval 1 Unsupported, ambiguous or partial stored lineage inventory.
certbotbot_state_lineage() {
  local config="$1" selected="$2" root member base name
  local -A names=()
  for root in live archive renewal; do
    if [[ -e "$config/$root" || -L "$config/$root" ]]; then
      [[ -d "$config/$root" && ! -L "$config/$root" ]] || return 1
      for member in "$config/$root/"* "$config/$root/".*; do
        [[ -e "$member" || -L "$member" ]] || continue
        base="${member##*/}"
        case "$base" in
          .|..) continue ;;
          README)
            [[ -f "$member" && ! -L "$member" ]] || return 1
            continue
            ;;
        esac
        if [[ "$root" == renewal ]]; then
          [[ "$base" == *.conf && -f "$member" &&
            ! -L "$member" && -s "$member" && -O "$member" ]] || return 1
          name="${base%.conf}"
        else
          [[ -d "$member" && ! -L "$member" && -O "$member" ]] || return 1
          name="$base"
        fi
        [[ "$name" != *'*'* ]] && certbotbot_dns_valid "$name" || return 1
        names["$name"]=1
      done
    fi
  done

  for name in "${!names[@]}"; do
    certbotbot_state_lineage_one "$config" "$name" || return 1
  done
  if [[ -n "${names[$selected]+x}" ]]; then
    REPLY=present
  else
    REPLY=absent
  fi
  return 0
}

## @fn certbotbot_state_canonical_all()
## @brief Verifies canonical renewal metadata for every stored certificate.
## @details
## The selected name is an operation target, not a filter for state safety.
## Before provider execution and before publication, verify all persisted
## renewal files against the supported production account/Route53 dialect.
## This function must only run when renewal paths are canonical: never between
## selected prepare/finalize operations. The read-only mapper uses ordinary
## structural preflight and does not rewrite any renewal file in verify mode.
## @param config Canonical owned restored configuration directory.
## @param selected Exact validated current selected lineage name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-secret diagnostics only.
## @retval 0 Every archived lineage has canonical supported metadata.
## @retval 65 Any incomplete or noncanonical archive state.
certbotbot_state_canonical_all() {
  local config="$1" selected="$2" file base name selected_state
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: unsupported shared archive state' >&2
    return 65
  fi
  # The verifier checks other lineages under their own names. Preserve the
  # selected absent/present result used by the public dispatcher.
  selected_state="$CERTBOTBOT_LINEAGE_STATE"
  for file in "$config/renewal/"*.conf; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    base="${file##*/}"
    name="${base%.conf}"
    if ! certbotbot_renewal_map "$config" "$name" verify >/dev/null 2>&1; then
      printf '%s\n' 'certbotbot: unsupported archived renewal metadata' >&2
      return 65
    fi
  done
  CERTBOTBOT_LINEAGE_STATE="$selected_state"
  return 0
}

## @fn certbotbot_state_unselected_fingerprint()
## @brief Hashes unchanged lineage payloads outside the selected namespace.
## @details
## Includes all other lineages' renewal configs, versioned PEMs, private-key
## permissions and live symlink targets. A normalized tar stream is hashed
## without writing or logging certificate or account material. This digest
## detects unintended changes to unselected state across a selected provider
## call; it is not a lock or cryptographic proof of remote S3 atomicity.
## @param config Restored private Certbot configuration tree.
## @param selected Selected lineage name to exclude from this digest.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One SHA-256 digest, with no certificate or account material.
## @par STDERR
## Nothing is written to STDERR.
## @returns A fingerprint of all unselected stored lineage data.
## @retval 0 Stable digest calculated for complete archive inventory.
## @retval 1 Tooling or state inspection unavailable.
certbotbot_state_unselected_fingerprint() {
  local config="$1" selected="$2" file name
  local -a items=()
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  for file in "$config/renewal/"*.conf; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    name="${file##*/}"
    name="${name%.conf}"
    [[ "$name" == "$selected" ]] && continue
    items+=("renewal/$name.conf" "live/$name" "archive/$name")
  done
  if (( ${#items[@]} == 0 )); then
    sha256sum </dev/null | cut -d' ' -f1
  else
    (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 \
      --numeric-owner --format=gnu -cf - -C "$config" "${items[@]}" \
      2>/dev/null | sha256sum | cut -d' ' -f1)
  fi
}

## @fn certbotbot_state_preflight()
## @brief Verifies restored account and selected lineage without side effects.
## @details
## This function is valid only after a private archive restoration. It
## checks canonical ownership/privacy, a single recognized ACME account,
## absence of archived hook execution, and one coherent selected lineage.
## Result is set in CERTBOTBOT_LINEAGE_STATE and cleared on all failures.
## It never invokes Certbot/AWS, reads the host account, or writes to S3.
## @param config Absolute canonical path of the private restored config root.
## @param selected Validated non-wildcard certificate name.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## One fixed safe diagnostic on failure.
## @returns Nothing is written to STDOUT.
## @retval 0 Local account structure and selected lineage are unambiguous.
## @retval 64 Invalid caller path or certificate name.
## @retval 65 Local restored state is missing, ambiguous, or unsafe.
## @par Examples
## @code
## certbotbot_state_preflight "$workspace/config" "$CERTBOTBOT_CERT_NAME" ||
##   exit $?
## # Certbot must still verify the account and canonical path mapping.
## @endcode
certbotbot_state_preflight() {
  local config selected physical
  CERTBOTBOT_LINEAGE_STATE=''
  if (( $# != 2 )); then
    printf '%s\n' 'certbotbot: invalid restored state arguments' >&2
    return 64
  fi
  config="$1"
  selected="$2"
  if [[ "$config" != /* || ! -d "$config" || -L "$config" ||
    ! -O "$config" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected"; then
    printf '%s\n' 'certbotbot: invalid restored state input' >&2
    return 64
  fi
  physical="$(cd -P -- "$config" && pwd -P)" || return 64
  if [[ "$physical" != "$config" ||
    "$(stat -c %a -- "$config" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe restored configuration root' >&2
    return 64
  fi
  if ! certbotbot_state_account "$config" ||
    ! certbotbot_state_hooks "$config" ||
    ! certbotbot_state_lineage "$config" "$selected"; then
    printf '%s\n' 'certbotbot: restored account or lineage is unsuitable' >&2
    return 65
  fi
  # The selected state is consumed by the later lifecycle module.
  # shellcheck disable=SC2034
  CERTBOTBOT_LINEAGE_STATE="$REPLY"
  return 0
}
