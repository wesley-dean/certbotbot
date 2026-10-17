# shellcheck shell=bash
## @file lib/import-candidate.bash
## @brief Builds a complete private, non-activating Certbot import candidate.
## @details
## ADR-045 permits a disposable candidate assembled from a frozen common
## account archive and every selected lineage only after ADR-037's full batch
## assessment succeeds. The candidate is deliberately NOT the recorded active
## CERTBOTBOT_WORKSPACE_CONFIG. It must never be passed to Certbot or moved
## into the active configuration before a separately accepted activation ADR
## and genuine Let's Encrypt staging evidence.
##
## This operation is fail-closed. A rejected late lineage discards the entire
## candidate, including earlier successful lineage copies; the active config
## directory is never changed. No network, DNS, GPG, or AWS operation occurs.
## @see doc/adr/ADR-045-nonactivating-multilineage-import-candidates.md

## @var CERTBOTBOT_IMPORT_CANDIDATE_ROOT
## @brief The owner-private prepared candidate directory, or empty.
CERTBOTBOT_IMPORT_CANDIDATE_ROOT=''

## @var CERTBOTBOT_IMPORT_CANDIDATE_CONFIG
## @brief Path to the prepared inactive Certbot-style config, or empty.
CERTBOTBOT_IMPORT_CANDIDATE_CONFIG=''

## @fn certbotbot_import_candidate_discard()
## @brief Destroys the currently recorded, exclusively owned candidate.
## @retval 0 No candidate was recorded or its private stage was removed.
## @retval 73 Candidate ownership, path, mode, or removal was unsafe.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
## @note Ordinary deletion cannot guarantee secure erasure of account keys.
certbotbot_import_candidate_discard() {
  local root=${CERTBOTBOT_IMPORT_CANDIDATE_ROOT:-} mode=''
  [[ -n $root ]] || return 0
  if [[ -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    $root != "$CERTBOTBOT_WORKSPACE_ROOT"/import-candidate.???????? ||
    ! ${root##*/} =~ ^import-candidate[.][a-zA-Z0-9]{8}$ ||
    ! -d $root || -L $root || ! -O $root ||
    ${CERTBOTBOT_IMPORT_CANDIDATE_CONFIG:-} != "$root/config" ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 73
  rm -rf -- "$root" || return 73
  CERTBOTBOT_IMPORT_CANDIDATE_ROOT=''
  # Consumed by the caller after standalone artifact assembly.
  # shellcheck disable=SC2034
  CERTBOTBOT_IMPORT_CANDIDATE_CONFIG=''
}

## @fn certbotbot_import_candidate_preview()
## @brief Creates a path-rebased renewal file solely inside a private candidate.
## @details
## A command-scoped Bash assignment temporarily targets the candidate
## config for ADR-032 previewing, preserving the caller's recorded active
## configuration path. The normal preview retains the complete ADR-031/038 validation
## chain; it is never installed into the active Certbot configuration.
## @param candidate_config Owner-private candidate config root.
## @param name Canonical selected lineage.
## @param environment Selected ACME environment.
## @retval 0 The approved inactive renewal file was created.
## @retval 64 Rejected renewal metadata or invalid configuration.
## @retval 65 Account/lineage identity mismatch.
## @retval 73 Private copy or preview cleanup failure.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_import_candidate_preview() {
  local target=${1:-} name=${2:-} environment=${3:-}
  (( $# == 3 )) || return 64
  [[ -n ${CERTBOTBOT_WORKSPACE_ROOT:-} &&
    $target == "$CERTBOTBOT_WORKSPACE_ROOT"/import-candidate.????????/config ]] ||
    return 64
  [[ -d $target && ! -L $target && -O $target ]] || return 64
  # Bash temporarily scopes this variable to the called function.  The
  # caller's recorded active config path remains unchanged on return.
  if CERTBOTBOT_WORKSPACE_CONFIG="$target" \
    certbotbot_renewal_path_preview "$name" "$environment"; then
    :
  else
    return $?
  fi
  if ! cp -- "$CERTBOTBOT_RENEWAL_PREVIEW" "$target/renewal/$name.conf"; then
    certbotbot_renewal_preview_discard || return 73
    return 73
  fi
  certbotbot_renewal_preview_discard || return 73
}

## @fn certbotbot_import_candidate_prepare()
## @brief Freeze, assess, and assemble a complete, inactive multi-lineage tree.
## @details
## Input identity is checked before staging. Archives are frozen once into
## owner-only private files; the existing batch assessor validates precisely
## those bytes. The approved common account is restored once into a private
## candidate. Each selected domain is restored separately, copied with its
## internal relative symlinks intact, and given a fresh non-activating renewal
## preview targeting the candidate, NOT active config.
##
## This is purely preparatory. The candidate is not certified for live Certbot
## use, which remains prohibited by ADR-037 without real staging evidence,
## certificate trust/SAN checks, and a separate activation decision.
##
## @param common_archive Absolute common-account archive path.
## @param environment production or staging (must match the process mode).
## @param ... One or more (canonical lineage, domain archive path) pairs.
## @retval 0 Complete private tree available in candidate result variables.
## @retval 64 Invalid request, archive, renewal policy, or unsafe workspace.
## @retval 65 Account identity or authority mismatch.
## @retval 73 Local snapshot, staging, assembly, or cleanup failure.
## @note Existing validator statuses are propagated where meaningful.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_import_candidate_prepare() {
  local common=${1:-} environment=${2:-} root='' target=''
  local name='' archive='' frozen='' result=0 index=0 mode='' item='' kind=''
  local cleanup_failed=false
  local -a requests=() copies=() pairs=()
  local -A names=() paths=()

  if (( $# < 4 || ($# - 2) % 2 != 0 || $# > 66 )) ||
    [[ -n ${CERTBOTBOT_IMPORT_CANDIDATE_ROOT:-} ||
      -n ${CERTBOTBOT_IMPORT_CANDIDATE_CONFIG:-} ||
      -n ${CERTBOTBOT_COMMON_STAGE:-} ||
      -n ${CERTBOTBOT_RESTORE_ROOT:-} ||
      -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ||
      -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
      -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ||
      $common != /* || ! -f $common || -L $common ||
      ! -O $common || ! -r $common ]] ||
    ! certbotbot_acme_validate_environment "$environment" ||
    [[ $environment != "${ACME_ENVIRONMENT:-production}" ]]; then
    return 64
  fi
  if [[ ! -d $CERTBOTBOT_WORKSPACE_ROOT ||
    -L $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -O $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -d $CERTBOTBOT_WORKSPACE_CONFIG ||
    -L $CERTBOTBOT_WORKSPACE_CONFIG ||
    ! -O $CERTBOTBOT_WORKSPACE_CONFIG ]]; then
    return 64
  fi
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" || return 73
  [[ $mode == 700 ]] || return 64
  mode="$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_CONFIG")" || return 73
  [[ $mode == 700 ]] || return 64
  item="$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" -mindepth 1 -print -quit)" ||
    return 73
  [[ -z $item ]] || return 64

  requests=("${@:3}")
  for (( index=0; index<${#requests[@]}; index+=2 )); do
    name=${requests[index]}
    archive=${requests[index+1]}
    if ! certbotbot_validate_hostname "$name" ||
      [[ $name == \*.* || $name != "${name,,}" ||
        -n ${names[$name]+_} ||
        $archive != /* || ! -f $archive || -L $archive ||
        ! -O $archive || ! -r $archive ||
        $archive == "$common" || $archive -ef "$common" ||
        -n ${paths[$archive]+_} ]]; then
      return 64
    fi
    names["$name"]=1
    paths["$archive"]=1
  done

  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/import-candidate.XXXXXXXX")" || return 73
  target="$root/config"
  if ! mkdir -m 0700 -- "$target" "$root/snapshots"; then
    rm -rf -- "$root" || return 73
    return 73
  fi

  # No validation path can observe changed source bytes after this point.
  frozen="$(mktemp -- "$root/snapshots/common.XXXXXXXX")" || result=73
  if (( result == 0 )); then
    if ! (umask 077; cp -- "$common" "$frozen" &&
      chmod 0600 -- "$frozen"); then
      result=73
    fi
  fi
  if (( result == 0 )); then
    copies+=("$frozen")
    for (( index=0; index<${#requests[@]}; index+=2 )); do
      frozen="$(mktemp -- "$root/snapshots/domain.XXXXXXXX")" || {
        result=73
        break
      }
      if ! (umask 077; cp -- "${requests[index+1]}" "$frozen" &&
        chmod 0600 -- "$frozen"); then
        result=73
        break
      fi
      copies+=("$frozen")
      pairs+=("${requests[index]}" "$frozen")
    done
  fi

  if (( result == 0 )); then
    certbotbot_import_assess_batch "${copies[0]}" "$environment" \
      "${pairs[@]}" || result=$?
  fi

  if (( result == 0 )); then
    if certbotbot_common_restore "${copies[0]}"; then
      cp -a -- "$CERTBOTBOT_COMMON_STAGE/accounts" "$target/accounts" ||
        result=73
      # Keep the validated account stage available through every lineage
      # identity check and renewal-path preview. Cleanup happens below.
    else
      result=$?
    fi
  fi

  if (( result == 0 )); then
    if ! mkdir -m 0700 -- "$target/archive" "$target/live" \
      "$target/renewal" "$target/combined"; then
      result=73
    fi
  fi

  if (( result == 0 )); then
    for (( index=0; index<${#requests[@]}; index+=2 )); do
      name=${requests[index]}
      archive=${copies[index/2+1]}
      if certbotbot_restore_domain "$archive" "$name"; then
        certbotbot_state_verify_identity \
          "$CERTBOTBOT_COMMON_STAGE" "$CERTBOTBOT_RESTORE_ROOT" \
          "$name" "$environment" || result=$?
        if (( result == 0 )); then
          certbotbot_renewal_policy_check "$name" "$environment" ||
            result=$?
        fi
        if (( result == 0 )); then
          if ! cp -a -- "$CERTBOTBOT_RESTORE_ROOT/archive/$name" \
            "$target/archive/$name" ||
            ! cp -a -- "$CERTBOTBOT_RESTORE_ROOT/live/$name" \
              "$target/live/$name" ||
            ! cp -p -- "$CERTBOTBOT_RESTORE_ROOT/combined/$name.pem" \
              "$target/combined/$name.pem"; then
            result=73
          fi
        fi
        if (( result == 0 )); then
          certbotbot_import_candidate_preview "$target" "$name" \
            "$environment" || result=$?
        fi
        if (( result == 0 )); then
          for kind in cert chain fullchain privkey; do
            certbotbot_pem_check_link "$target" "$name" "$kind" ||
              { result=64; break; }
          done
        fi
        certbotbot_restore_discard || cleanup_failed=true
      else
        result=$?
      fi
      (( result == 0 )) || break
    done
  fi

  # No partially populated candidate or snapshots survive an error.
  # The final candidate is exposed only once every lineage is installed
  # under its private, non-active directory and all temporary state is gone.
  if [[ -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ]]; then
    certbotbot_renewal_preview_discard || cleanup_failed=true
  fi
  if [[ -n ${CERTBOTBOT_RESTORE_ROOT:-} ]]; then
    certbotbot_restore_discard || cleanup_failed=true
  fi
  if [[ -n ${CERTBOTBOT_COMMON_STAGE:-} ]]; then
    certbotbot_common_discard || cleanup_failed=true
  fi
  if [[ $cleanup_failed == true ]]; then
    result=73
  fi
  if (( result == 0 )); then
    rm -rf -- "$root/snapshots" || result=73
  fi
  if (( result != 0 )); then
    rm -rf -- "$root" || return 73
    return "$result"
  fi
  CERTBOTBOT_IMPORT_CANDIDATE_ROOT=$root
  # Caller-facing variable consumed from the assembled standalone artifact.
  # shellcheck disable=SC2034
  CERTBOTBOT_IMPORT_CANDIDATE_CONFIG=$target
  return 0
}
