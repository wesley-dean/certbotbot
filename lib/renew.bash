#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/renew.bash
## @brief Renews only one restored Certbot lineage and classifies local changes.
## @details
## ADR-025 permits normal due-renewal only for an already selected and fully
## restored lineage with exactly matching current and desired DNS SANs.
## Path mapping is reversible, and returned result variables reflect only
## verified local state, never remote S3 publication. Unknown SAN drift must
## fail closed until its separately approved reconciliation is implemented.
## The installed Certbot and Route53 plugin retain ACME/DNS authority.

## @fn certbotbot_renew_sans_match()
## @brief Checks the selected leaf's exact DNS SAN set through OpenSSL.
## @details
## The supported OpenSSL output has one extension label (optionally with\n## whitespace after the colon) and one comma-separated
## list of DNS: entries. Other extensions, multiline values, missing SANs,
## unknown SAN kinds, invalid names and duplicates fail closed. Comparison is
## set-based; order of names is irrelevant. OpenSSL output is kept private.
## @param cert Absolute readable PEM certificate path from selected live tree.
## @param ... One or two validated and distinct desired DNS SAN strings.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Nothing is written to STDERR.
## @returns Nothing is written to STDOUT.
## @retval 0 OpenSSL certificate DNS SANs match the desired names exactly.
## @retval 1 Missing OpenSSL, unsupported output or nonmatching names.
certbotbot_renew_sans_match() {
  local cert="$1" output line item name found
  local -a actual=() parts=()
  shift
  [[ -f "$cert" && -r "$cert" ]] || return 1
  certbotbot_provider_sans "$@" || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  output="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)" ||
    return 1
  [[ "$output" == *
  [[ "$line" != *$'\n'* ]] || return 1
  IFS=, read -r -a parts <<< "$line"
  (( ${#parts[@]} >= 1 && ${#parts[@]} <= 2 )) || return 1
  for item in "${parts[@]}"; do
    if [[ "$item" =~ ^[[:blank:]]*DNS:([^[:blank:],]+)[[:blank:]]*$ ]]; then
      name="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    certbotbot_dns_valid "$name" || return 1
    [[ "$name" == "${name,,}" ]] || return 1
    for found in "${actual[@]}"; do
      [[ "$found" != "$name" ]] || return 1
    done
    actual+=("$name")
  done
  (( ${#actual[@]} == $# )) || return 1
  for item in "$@"; do
    found=false
    for name in "${actual[@]}"; do
      if [[ "$item" == "$name" ]]; then found=true; break; fi
    done
    [[ "$found" == true ]] || return 1
  done
  return 0
}

## @fn certbotbot_renew_fingerprint()
## @brief Computes a stable private digest of all persistent config state.
## @details
## GNU tar recursively serializes configuration in name order with fixed
## modification time, owner and group metadata; permissions, file bytes and
## symbolic-link targets remain part of the digest. GNU sha256sum hashes the
## byte stream; neither stream nor hash is emitted outside the caller.
## This is local change detection, not a filesystem transaction or lock.
## @param config Private Certbot configuration directory to inspect.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One lowercase SHA-256 digest followed by newline.
## @par STDERR
## Nothing is written to STDERR.
## @returns SHA-256 digest of the normalized local archive stream.
## @retval 0 Snapshot completed successfully.
## @retval 1 A required tool or tar/hash stage failed.
certbotbot_renew_fingerprint() {
  local config="$1"
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu -cf - -C "$config" . 2>/dev/null | sha256sum | cut -d' ' -f1)
}

## @fn certbotbot_provider_renew()
## @brief Renews one existing lineage when due, preserving ordinary no-ops.
## @details
## A private canonical workspace and its one restored selected lineage must
## pass local preflight. DNS SANs in the leaf PEM must match requested SANs.
## A mismatch is an explicit policy failure, not an implicit reissue.
##
## Installed Certbot must list dns-route53 and recognize the exact restored
## account. The provider maps five canonical renewal path fields to private
## paths, then invokes 'certbot renew --cert-name NAME' with explicit
## private directories, account, production ACME server, noninteractive mode,
## and hook suppression. It validates resulting lineage and SANs, returns
## renewal paths to canonical form, and compares durable state fingerprints.
## It never invokes global renew, register, forced renewal or publication.
##
## CERTBOTBOT_RENEWAL_OCCURRED and CERTBOTBOT_DURABLE_CHANGED are cleared at
## entry and on failure; on success they are set to true or false. The first
## indicates whether selected certificate content/link changed. The second
## detects any changed restored configuration bytes, links or permissions.
## The caller must still validate a candidate archive prior to remote writes.
## @param workspace Owned canonical mode-0700 private runner directory.
## @param selected Stable non-wildcard selected Certbot certificate name.
## @param ... Exact desired literal SANs (one or complementary pair).
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-sensitive diagnostics; Certbot output is not forwarded.
## @returns Nothing is written to STDOUT.
## @retval 0 Selected-only renewal completed and local state is coherent.
## @retval 64 Unsafe workspace, identity or requested SAN set.
## @retval 65 Mismatched SANs or inconsistent/unsafe local renewal state.
## @retval 69 Installed provider unavailable or account not recognized.
## @retval 74 Failed Certbot invocation or local snapshot/staging.
## @par Examples
## @code
## certbotbot_provider_renew "$workspace" "$name" "${sans[@]}" || exit $?
## # Combine durable-change result with UPLOAD_NO_RENEWAL later.
## @endcode
certbotbot_provider_renew() {
  local workspace selected config physical work logs directory entry
  local account='' listing current_cert before_link after_link
  local before_cert after_cert before_state after_state
  local -a common=()
  CERTBOTBOT_RENEWAL_OCCURRED=''
  CERTBOTBOT_DURABLE_CHANGED=''
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid selected renewal arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  shift 2
  if [[ "$workspace" != /* || "$workspace" == / ||
    ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    "$workspace" == */ || ! -d "$workspace" || -L "$workspace" ||
    ! -O "$workspace" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected" ||
    ! certbotbot_provider_sans "$@"; then
    printf '%s\n' 'certbotbot: invalid selected renewal input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe selected renewal workspace' >&2
    return 64
  fi
  config="$workspace/config"
  work="$workspace/work"
  logs="$workspace/logs"
  for directory in "$work" "$logs"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ||
        "$(stat -c %a -- "$directory" 2>/dev/null)" != 700 ]]; then
        printf '%s\n' 'certbotbot: unsafe private Certbot directories' >&2
        return 64
      fi
    fi
  done
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: existing selected lineage is unsuitable' >&2
    return 65
  fi
  current_cert="$config/live/$selected/cert.pem"
  if ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: selected certificate SANs differ or are unsafe' >&2
    return 65
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: installed Certbot is required' >&2
    return 69
  fi
  for directory in "$work" "$logs"; do
    if [[ ! -e "$directory" ]] &&
      ! (umask 077; mkdir -m 700 -- "$directory"); then
      printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
      return 74
    fi
  done

  directory="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$directory/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account="${entry##*/}"
    break
  done
  if [[ ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' 'certbotbot: unsupported ACME account identity' >&2
    return 65
  fi
  common=(--config-dir "$config" --work-dir "$work" --logs-dir "$logs" --server https://acme-v02.api.letsencrypt.org/directory --non-interactive --no-directory-hooks)

  listing="$(umask 077; mktemp "$logs/plugins.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
    return 74
  }
  if ! command certbot plugins --authenticators "${common[@]}" \
    >"$listing" 2>/dev/null; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot authenticator probe failed' >&2
    return 69
  fi
  if ! LC_ALL=C grep -Eq '^[[:space:]]*\*[[:space:]]+dns-route53([[:space:]]|$)' "$listing"; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot Route53 authenticator unavailable' >&2
    return 69
  fi
  rm -f -- "$listing"
  if ! command certbot show_account --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: account is not recognized by Certbot' >&2
    return 69
  fi

  before_link="$(readlink -- "$current_cert")" || return 65
  before_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  before_cert="${before_cert%% *}"
  before_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect durable certificate state' >&2
    return 74
  }
  if ! certbotbot_renewal_map "$config" "$selected" prepare >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: private renewal path preparation failed' >&2
    return 65
  fi
  if ! command certbot renew --cert-name "$selected" --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate renewal failed' >&2
    return 74
  fi
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: renewed certificate state is unsuitable' >&2
    return 65
  fi
  if ! certbotbot_renewal_map "$config" "$selected" finalize >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: canonical renewal path restoration failed' >&2
    return 65
  fi
  after_link="$(readlink -- "$current_cert")" || return 65
  after_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  after_cert="${after_cert%% *}"
  after_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect renewed durable state' >&2
    return 74
  }
  # shellcheck disable=SC2034
  CERTBOTBOT_RENEWAL_OCCURRED=false
  # shellcheck disable=SC2034
  CERTBOTBOT_DURABLE_CHANGED=false
  if [[ "$before_link" != "$after_link" ||
    "$before_cert" != "$after_cert" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_RENEWAL_OCCURRED=true
  fi
  if [[ "$before_state" != "$after_state" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_DURABLE_CHANGED=true
  fi
  return 0
}
\n'* ]] || return 1
  line="${output%%
  [[ "$line" != *$'\n'* ]] || return 1
  IFS=, read -r -a parts <<< "$line"
  (( ${#parts[@]} >= 1 && ${#parts[@]} <= 2 )) || return 1
  for item in "${parts[@]}"; do
    if [[ "$item" =~ ^[[:blank:]]*DNS:([^[:blank:],]+)[[:blank:]]*$ ]]; then
      name="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    certbotbot_dns_valid "$name" || return 1
    [[ "$name" == "${name,,}" ]] || return 1
    for found in "${actual[@]}"; do
      [[ "$found" != "$name" ]] || return 1
    done
    actual+=("$name")
  done
  (( ${#actual[@]} == $# )) || return 1
  for item in "$@"; do
    found=false
    for name in "${actual[@]}"; do
      if [[ "$item" == "$name" ]]; then found=true; break; fi
    done
    [[ "$found" == true ]] || return 1
  done
  return 0
}

## @fn certbotbot_renew_fingerprint()
## @brief Computes a stable private digest of all persistent config state.
## @details
## GNU tar recursively serializes configuration in name order with fixed
## modification time, owner and group metadata; permissions, file bytes and
## symbolic-link targets remain part of the digest. GNU sha256sum hashes the
## byte stream; neither stream nor hash is emitted outside the caller.
## This is local change detection, not a filesystem transaction or lock.
## @param config Private Certbot configuration directory to inspect.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One lowercase SHA-256 digest followed by newline.
## @par STDERR
## Nothing is written to STDERR.
## @returns SHA-256 digest of the normalized local archive stream.
## @retval 0 Snapshot completed successfully.
## @retval 1 A required tool or tar/hash stage failed.
certbotbot_renew_fingerprint() {
  local config="$1"
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu -cf - -C "$config" . 2>/dev/null | sha256sum | cut -d' ' -f1)
}

## @fn certbotbot_provider_renew()
## @brief Renews one existing lineage when due, preserving ordinary no-ops.
## @details
## A private canonical workspace and its one restored selected lineage must
## pass local preflight. DNS SANs in the leaf PEM must match requested SANs.
## A mismatch is an explicit policy failure, not an implicit reissue.
##
## Installed Certbot must list dns-route53 and recognize the exact restored
## account. The provider maps five canonical renewal path fields to private
## paths, then invokes 'certbot renew --cert-name NAME' with explicit
## private directories, account, production ACME server, noninteractive mode,
## and hook suppression. It validates resulting lineage and SANs, returns
## renewal paths to canonical form, and compares durable state fingerprints.
## It never invokes global renew, register, forced renewal or publication.
##
## CERTBOTBOT_RENEWAL_OCCURRED and CERTBOTBOT_DURABLE_CHANGED are cleared at
## entry and on failure; on success they are set to true or false. The first
## indicates whether selected certificate content/link changed. The second
## detects any changed restored configuration bytes, links or permissions.
## The caller must still validate a candidate archive prior to remote writes.
## @param workspace Owned canonical mode-0700 private runner directory.
## @param selected Stable non-wildcard selected Certbot certificate name.
## @param ... Exact desired literal SANs (one or complementary pair).
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-sensitive diagnostics; Certbot output is not forwarded.
## @returns Nothing is written to STDOUT.
## @retval 0 Selected-only renewal completed and local state is coherent.
## @retval 64 Unsafe workspace, identity or requested SAN set.
## @retval 65 Mismatched SANs or inconsistent/unsafe local renewal state.
## @retval 69 Installed provider unavailable or account not recognized.
## @retval 74 Failed Certbot invocation or local snapshot/staging.
## @par Examples
## @code
## certbotbot_provider_renew "$workspace" "$name" "${sans[@]}" || exit $?
## # Combine durable-change result with UPLOAD_NO_RENEWAL later.
## @endcode
certbotbot_provider_renew() {
  local workspace selected config physical work logs directory entry
  local account='' listing current_cert before_link after_link
  local before_cert after_cert before_state after_state
  local -a common=()
  CERTBOTBOT_RENEWAL_OCCURRED=''
  CERTBOTBOT_DURABLE_CHANGED=''
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid selected renewal arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  shift 2
  if [[ "$workspace" != /* || "$workspace" == / ||
    ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    "$workspace" == */ || ! -d "$workspace" || -L "$workspace" ||
    ! -O "$workspace" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected" ||
    ! certbotbot_provider_sans "$@"; then
    printf '%s\n' 'certbotbot: invalid selected renewal input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe selected renewal workspace' >&2
    return 64
  fi
  config="$workspace/config"
  work="$workspace/work"
  logs="$workspace/logs"
  for directory in "$work" "$logs"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ||
        "$(stat -c %a -- "$directory" 2>/dev/null)" != 700 ]]; then
        printf '%s\n' 'certbotbot: unsafe private Certbot directories' >&2
        return 64
      fi
    fi
  done
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: existing selected lineage is unsuitable' >&2
    return 65
  fi
  current_cert="$config/live/$selected/cert.pem"
  if ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: selected certificate SANs differ or are unsafe' >&2
    return 65
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: installed Certbot is required' >&2
    return 69
  fi
  for directory in "$work" "$logs"; do
    if [[ ! -e "$directory" ]] &&
      ! (umask 077; mkdir -m 700 -- "$directory"); then
      printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
      return 74
    fi
  done

  directory="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$directory/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account="${entry##*/}"
    break
  done
  if [[ ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' 'certbotbot: unsupported ACME account identity' >&2
    return 65
  fi
  common=(--config-dir "$config" --work-dir "$work" --logs-dir "$logs" --server https://acme-v02.api.letsencrypt.org/directory --non-interactive --no-directory-hooks)

  listing="$(umask 077; mktemp "$logs/plugins.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
    return 74
  }
  if ! command certbot plugins --authenticators "${common[@]}" \
    >"$listing" 2>/dev/null; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot authenticator probe failed' >&2
    return 69
  fi
  if ! LC_ALL=C grep -Eq '^[[:space:]]*\*[[:space:]]+dns-route53([[:space:]]|$)' "$listing"; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot Route53 authenticator unavailable' >&2
    return 69
  fi
  rm -f -- "$listing"
  if ! command certbot show_account --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: account is not recognized by Certbot' >&2
    return 69
  fi

  before_link="$(readlink -- "$current_cert")" || return 65
  before_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  before_cert="${before_cert%% *}"
  before_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect durable certificate state' >&2
    return 74
  }
  if ! certbotbot_renewal_map "$config" "$selected" prepare >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: private renewal path preparation failed' >&2
    return 65
  fi
  if ! command certbot renew --cert-name "$selected" --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate renewal failed' >&2
    return 74
  fi
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: renewed certificate state is unsuitable' >&2
    return 65
  fi
  if ! certbotbot_renewal_map "$config" "$selected" finalize >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: canonical renewal path restoration failed' >&2
    return 65
  fi
  after_link="$(readlink -- "$current_cert")" || return 65
  after_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  after_cert="${after_cert%% *}"
  after_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect renewed durable state' >&2
    return 74
  }
  # shellcheck disable=SC2034
  CERTBOTBOT_RENEWAL_OCCURRED=false
  # shellcheck disable=SC2034
  CERTBOTBOT_DURABLE_CHANGED=false
  if [[ "$before_link" != "$after_link" ||
    "$before_cert" != "$after_cert" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_RENEWAL_OCCURRED=true
  fi
  if [[ "$before_state" != "$after_state" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_DURABLE_CHANGED=true
  fi
  return 0
}
\n'*}"
  [[ "$line" =~ ^X509v3[[:space:]]Subject[[:space:]]Alternative[[:space:]]Name:[[:blank:]]*$ ]] || return 1
  line="${output#*
  [[ "$line" != *$'\n'* ]] || return 1
  IFS=, read -r -a parts <<< "$line"
  (( ${#parts[@]} >= 1 && ${#parts[@]} <= 2 )) || return 1
  for item in "${parts[@]}"; do
    if [[ "$item" =~ ^[[:blank:]]*DNS:([^[:blank:],]+)[[:blank:]]*$ ]]; then
      name="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    certbotbot_dns_valid "$name" || return 1
    [[ "$name" == "${name,,}" ]] || return 1
    for found in "${actual[@]}"; do
      [[ "$found" != "$name" ]] || return 1
    done
    actual+=("$name")
  done
  (( ${#actual[@]} == $# )) || return 1
  for item in "$@"; do
    found=false
    for name in "${actual[@]}"; do
      if [[ "$item" == "$name" ]]; then found=true; break; fi
    done
    [[ "$found" == true ]] || return 1
  done
  return 0
}

## @fn certbotbot_renew_fingerprint()
## @brief Computes a stable private digest of all persistent config state.
## @details
## GNU tar recursively serializes configuration in name order with fixed
## modification time, owner and group metadata; permissions, file bytes and
## symbolic-link targets remain part of the digest. GNU sha256sum hashes the
## byte stream; neither stream nor hash is emitted outside the caller.
## This is local change detection, not a filesystem transaction or lock.
## @param config Private Certbot configuration directory to inspect.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One lowercase SHA-256 digest followed by newline.
## @par STDERR
## Nothing is written to STDERR.
## @returns SHA-256 digest of the normalized local archive stream.
## @retval 0 Snapshot completed successfully.
## @retval 1 A required tool or tar/hash stage failed.
certbotbot_renew_fingerprint() {
  local config="$1"
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu -cf - -C "$config" . 2>/dev/null | sha256sum | cut -d' ' -f1)
}

## @fn certbotbot_provider_renew()
## @brief Renews one existing lineage when due, preserving ordinary no-ops.
## @details
## A private canonical workspace and its one restored selected lineage must
## pass local preflight. DNS SANs in the leaf PEM must match requested SANs.
## A mismatch is an explicit policy failure, not an implicit reissue.
##
## Installed Certbot must list dns-route53 and recognize the exact restored
## account. The provider maps five canonical renewal path fields to private
## paths, then invokes 'certbot renew --cert-name NAME' with explicit
## private directories, account, production ACME server, noninteractive mode,
## and hook suppression. It validates resulting lineage and SANs, returns
## renewal paths to canonical form, and compares durable state fingerprints.
## It never invokes global renew, register, forced renewal or publication.
##
## CERTBOTBOT_RENEWAL_OCCURRED and CERTBOTBOT_DURABLE_CHANGED are cleared at
## entry and on failure; on success they are set to true or false. The first
## indicates whether selected certificate content/link changed. The second
## detects any changed restored configuration bytes, links or permissions.
## The caller must still validate a candidate archive prior to remote writes.
## @param workspace Owned canonical mode-0700 private runner directory.
## @param selected Stable non-wildcard selected Certbot certificate name.
## @param ... Exact desired literal SANs (one or complementary pair).
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-sensitive diagnostics; Certbot output is not forwarded.
## @returns Nothing is written to STDOUT.
## @retval 0 Selected-only renewal completed and local state is coherent.
## @retval 64 Unsafe workspace, identity or requested SAN set.
## @retval 65 Mismatched SANs or inconsistent/unsafe local renewal state.
## @retval 69 Installed provider unavailable or account not recognized.
## @retval 74 Failed Certbot invocation or local snapshot/staging.
## @par Examples
## @code
## certbotbot_provider_renew "$workspace" "$name" "${sans[@]}" || exit $?
## # Combine durable-change result with UPLOAD_NO_RENEWAL later.
## @endcode
certbotbot_provider_renew() {
  local workspace selected config physical work logs directory entry
  local account='' listing current_cert before_link after_link
  local before_cert after_cert before_state after_state
  local -a common=()
  CERTBOTBOT_RENEWAL_OCCURRED=''
  CERTBOTBOT_DURABLE_CHANGED=''
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid selected renewal arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  shift 2
  if [[ "$workspace" != /* || "$workspace" == / ||
    ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    "$workspace" == */ || ! -d "$workspace" || -L "$workspace" ||
    ! -O "$workspace" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected" ||
    ! certbotbot_provider_sans "$@"; then
    printf '%s\n' 'certbotbot: invalid selected renewal input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe selected renewal workspace' >&2
    return 64
  fi
  config="$workspace/config"
  work="$workspace/work"
  logs="$workspace/logs"
  for directory in "$work" "$logs"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ||
        "$(stat -c %a -- "$directory" 2>/dev/null)" != 700 ]]; then
        printf '%s\n' 'certbotbot: unsafe private Certbot directories' >&2
        return 64
      fi
    fi
  done
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: existing selected lineage is unsuitable' >&2
    return 65
  fi
  current_cert="$config/live/$selected/cert.pem"
  if ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: selected certificate SANs differ or are unsafe' >&2
    return 65
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: installed Certbot is required' >&2
    return 69
  fi
  for directory in "$work" "$logs"; do
    if [[ ! -e "$directory" ]] &&
      ! (umask 077; mkdir -m 700 -- "$directory"); then
      printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
      return 74
    fi
  done

  directory="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$directory/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account="${entry##*/}"
    break
  done
  if [[ ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' 'certbotbot: unsupported ACME account identity' >&2
    return 65
  fi
  common=(--config-dir "$config" --work-dir "$work" --logs-dir "$logs" --server https://acme-v02.api.letsencrypt.org/directory --non-interactive --no-directory-hooks)

  listing="$(umask 077; mktemp "$logs/plugins.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
    return 74
  }
  if ! command certbot plugins --authenticators "${common[@]}" \
    >"$listing" 2>/dev/null; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot authenticator probe failed' >&2
    return 69
  fi
  if ! LC_ALL=C grep -Eq '^[[:space:]]*\*[[:space:]]+dns-route53([[:space:]]|$)' "$listing"; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot Route53 authenticator unavailable' >&2
    return 69
  fi
  rm -f -- "$listing"
  if ! command certbot show_account --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: account is not recognized by Certbot' >&2
    return 69
  fi

  before_link="$(readlink -- "$current_cert")" || return 65
  before_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  before_cert="${before_cert%% *}"
  before_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect durable certificate state' >&2
    return 74
  }
  if ! certbotbot_renewal_map "$config" "$selected" prepare >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: private renewal path preparation failed' >&2
    return 65
  fi
  if ! command certbot renew --cert-name "$selected" --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate renewal failed' >&2
    return 74
  fi
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: renewed certificate state is unsuitable' >&2
    return 65
  fi
  if ! certbotbot_renewal_map "$config" "$selected" finalize >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: canonical renewal path restoration failed' >&2
    return 65
  fi
  after_link="$(readlink -- "$current_cert")" || return 65
  after_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  after_cert="${after_cert%% *}"
  after_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect renewed durable state' >&2
    return 74
  }
  # shellcheck disable=SC2034
  CERTBOTBOT_RENEWAL_OCCURRED=false
  # shellcheck disable=SC2034
  CERTBOTBOT_DURABLE_CHANGED=false
  if [[ "$before_link" != "$after_link" ||
    "$before_cert" != "$after_cert" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_RENEWAL_OCCURRED=true
  fi
  if [[ "$before_state" != "$after_state" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_DURABLE_CHANGED=true
  fi
  return 0
}
\n'}"
  [[ "$line" != *$'\n'* ]] || return 1
  IFS=, read -r -a parts <<< "$line"
  (( ${#parts[@]} >= 1 && ${#parts[@]} <= 2 )) || return 1
  for item in "${parts[@]}"; do
    if [[ "$item" =~ ^[[:blank:]]*DNS:([^[:blank:],]+)[[:blank:]]*$ ]]; then
      name="${BASH_REMATCH[1]}"
    else
      return 1
    fi
    certbotbot_dns_valid "$name" || return 1
    [[ "$name" == "${name,,}" ]] || return 1
    for found in "${actual[@]}"; do
      [[ "$found" != "$name" ]] || return 1
    done
    actual+=("$name")
  done
  (( ${#actual[@]} == $# )) || return 1
  for item in "$@"; do
    found=false
    for name in "${actual[@]}"; do
      if [[ "$item" == "$name" ]]; then found=true; break; fi
    done
    [[ "$found" == true ]] || return 1
  done
  return 0
}

## @fn certbotbot_renew_fingerprint()
## @brief Computes a stable private digest of all persistent config state.
## @details
## GNU tar recursively serializes configuration in name order with fixed
## modification time, owner and group metadata; permissions, file bytes and
## symbolic-link targets remain part of the digest. GNU sha256sum hashes the
## byte stream; neither stream nor hash is emitted outside the caller.
## This is local change detection, not a filesystem transaction or lock.
## @param config Private Certbot configuration directory to inspect.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## One lowercase SHA-256 digest followed by newline.
## @par STDERR
## Nothing is written to STDERR.
## @returns SHA-256 digest of the normalized local archive stream.
## @retval 0 Snapshot completed successfully.
## @retval 1 A required tool or tar/hash stage failed.
certbotbot_renew_fingerprint() {
  local config="$1"
  command -v tar >/dev/null 2>&1 || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  (set -o pipefail; tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu -cf - -C "$config" . 2>/dev/null | sha256sum | cut -d' ' -f1)
}

## @fn certbotbot_provider_renew()
## @brief Renews one existing lineage when due, preserving ordinary no-ops.
## @details
## A private canonical workspace and its one restored selected lineage must
## pass local preflight. DNS SANs in the leaf PEM must match requested SANs.
## A mismatch is an explicit policy failure, not an implicit reissue.
##
## Installed Certbot must list dns-route53 and recognize the exact restored
## account. The provider maps five canonical renewal path fields to private
## paths, then invokes 'certbot renew --cert-name NAME' with explicit
## private directories, account, production ACME server, noninteractive mode,
## and hook suppression. It validates resulting lineage and SANs, returns
## renewal paths to canonical form, and compares durable state fingerprints.
## It never invokes global renew, register, forced renewal or publication.
##
## CERTBOTBOT_RENEWAL_OCCURRED and CERTBOTBOT_DURABLE_CHANGED are cleared at
## entry and on failure; on success they are set to true or false. The first
## indicates whether selected certificate content/link changed. The second
## detects any changed restored configuration bytes, links or permissions.
## The caller must still validate a candidate archive prior to remote writes.
## @param workspace Owned canonical mode-0700 private runner directory.
## @param selected Stable non-wildcard selected Certbot certificate name.
## @param ... Exact desired literal SANs (one or complementary pair).
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed non-sensitive diagnostics; Certbot output is not forwarded.
## @returns Nothing is written to STDOUT.
## @retval 0 Selected-only renewal completed and local state is coherent.
## @retval 64 Unsafe workspace, identity or requested SAN set.
## @retval 65 Mismatched SANs or inconsistent/unsafe local renewal state.
## @retval 69 Installed provider unavailable or account not recognized.
## @retval 74 Failed Certbot invocation or local snapshot/staging.
## @par Examples
## @code
## certbotbot_provider_renew "$workspace" "$name" "${sans[@]}" || exit $?
## # Combine durable-change result with UPLOAD_NO_RENEWAL later.
## @endcode
certbotbot_provider_renew() {
  local workspace selected config physical work logs directory entry
  local account='' listing current_cert before_link after_link
  local before_cert after_cert before_state after_state
  local -a common=()
  CERTBOTBOT_RENEWAL_OCCURRED=''
  CERTBOTBOT_DURABLE_CHANGED=''
  if (( $# < 3 )); then
    printf '%s\n' 'certbotbot: invalid selected renewal arguments' >&2
    return 64
  fi
  workspace="$1"
  selected="$2"
  shift 2
  if [[ "$workspace" != /* || "$workspace" == / ||
    ! "$workspace" =~ ^/[A-Za-z0-9._/-]+$ ||
    "$workspace" == */ || ! -d "$workspace" || -L "$workspace" ||
    ! -O "$workspace" || "$selected" == *'*'* ]] ||
    ! certbotbot_dns_valid "$selected" ||
    ! certbotbot_provider_sans "$@"; then
    printf '%s\n' 'certbotbot: invalid selected renewal input' >&2
    return 64
  fi
  physical="$(cd -P -- "$workspace" && pwd -P)" || return 64
  if [[ "$physical" != "$workspace" ||
    "$(stat -c %a -- "$workspace" 2>/dev/null)" != 700 ]]; then
    printf '%s\n' 'certbotbot: unsafe selected renewal workspace' >&2
    return 64
  fi
  config="$workspace/config"
  work="$workspace/work"
  logs="$workspace/logs"
  for directory in "$work" "$logs"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      if [[ ! -d "$directory" || -L "$directory" || ! -O "$directory" ||
        "$(stat -c %a -- "$directory" 2>/dev/null)" != 700 ]]; then
        printf '%s\n' 'certbotbot: unsafe private Certbot directories' >&2
        return 64
      fi
    fi
  done
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]]; then
    printf '%s\n' 'certbotbot: existing selected lineage is unsuitable' >&2
    return 65
  fi
  current_cert="$config/live/$selected/cert.pem"
  if ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: selected certificate SANs differ or are unsafe' >&2
    return 65
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: installed Certbot is required' >&2
    return 69
  fi
  for directory in "$work" "$logs"; do
    if [[ ! -e "$directory" ]] &&
      ! (umask 077; mkdir -m 700 -- "$directory"); then
      printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
      return 74
    fi
  done

  directory="$config/accounts/acme-v02.api.letsencrypt.org/directory"
  for entry in "$directory/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account="${entry##*/}"
    break
  done
  if [[ ! "$account" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf '%s\n' 'certbotbot: unsupported ACME account identity' >&2
    return 65
  fi
  common=(--config-dir "$config" --work-dir "$work" --logs-dir "$logs" --server https://acme-v02.api.letsencrypt.org/directory --non-interactive --no-directory-hooks)

  listing="$(umask 077; mktemp "$logs/plugins.XXXXXXXX")" || {
    printf '%s\n' 'certbotbot: private Certbot staging unavailable' >&2
    return 74
  }
  if ! command certbot plugins --authenticators "${common[@]}" \
    >"$listing" 2>/dev/null; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot authenticator probe failed' >&2
    return 69
  fi
  if ! LC_ALL=C grep -Eq '^[[:space:]]*\*[[:space:]]+dns-route53([[:space:]]|$)' "$listing"; then
    rm -f -- "$listing"
    printf '%s\n' 'certbotbot: Certbot Route53 authenticator unavailable' >&2
    return 69
  fi
  rm -f -- "$listing"
  if ! command certbot show_account --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: account is not recognized by Certbot' >&2
    return 69
  fi

  before_link="$(readlink -- "$current_cert")" || return 65
  before_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  before_cert="${before_cert%% *}"
  before_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect durable certificate state' >&2
    return 74
  }
  if ! certbotbot_renewal_map "$config" "$selected" prepare >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: private renewal path preparation failed' >&2
    return 65
  fi
  if ! command certbot renew --cert-name "$selected" --account "$account" \
    "${common[@]}" >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: selected certificate renewal failed' >&2
    return 74
  fi
  if ! certbotbot_state_preflight "$config" "$selected" >/dev/null 2>&1 ||
    [[ "$CERTBOTBOT_LINEAGE_STATE" != present ]] ||
    ! certbotbot_renew_sans_match "$current_cert" "$@"; then
    printf '%s\n' 'certbotbot: renewed certificate state is unsuitable' >&2
    return 65
  fi
  if ! certbotbot_renewal_map "$config" "$selected" finalize >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: canonical renewal path restoration failed' >&2
    return 65
  fi
  after_link="$(readlink -- "$current_cert")" || return 65
  after_cert="$(sha256sum -- "$current_cert" 2>/dev/null)" || return 65
  after_cert="${after_cert%% *}"
  after_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect renewed durable state' >&2
    return 74
  }
  # shellcheck disable=SC2034
  CERTBOTBOT_RENEWAL_OCCURRED=false
  # shellcheck disable=SC2034
  CERTBOTBOT_DURABLE_CHANGED=false
  if [[ "$before_link" != "$after_link" ||
    "$before_cert" != "$after_cert" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_RENEWAL_OCCURRED=true
  fi
  if [[ "$before_state" != "$after_state" ]]; then
    # shellcheck disable=SC2034
    CERTBOTBOT_DURABLE_CHANGED=true
  fi
  return 0
}
