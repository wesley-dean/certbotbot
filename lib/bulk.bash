#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/bulk.bash
## @brief Performs an explicitly opted-in, verified pass over archived lineages.
## @details
## Implements only the opt-in ADR-058 exception to ADR-030. A sorted snapshot
## of complete restored lineages is immutable for this invocation. Every
## archived identity is checked at most once through an exact named Certbot
## renewal, using the existing validated DNS SANs rather than runtime SAN
## expansion. The optional ordinary selected operation is distinct, and an
## explicitly new selected lineage is never enumerated a second time.
##
## The private workspace and all ACME/provider actions belong to the public
## lifecycle. This module never trusts an arbitrary host Certbot directory.
## Non-target fingerprints, exact membership checks, cryptographic verification,
## and the existing publisher gate suppress partial archive publication after
## local failure. Remote S3 write uncertainty and external writer serialization
## remain outside the module's guarantees.

## @fn certbotbot_bulk_verify_inventory()
## @brief Confirms exact expected lineage membership after a provider action.
## @details
## Runs whole-archive preflight and canonical metadata verification after each
## selected or bulk mutation. Compares valid discovered names to the original
## immutable set plus at most one explicitly issued selected lineage. Rejects
## unexpected creation, disappearance, duplicate, or rename even when the
## remaining lineages are individually well-formed.
## @param config Owned, canonical Certbot configuration root.
## @param probe Existing lineage used for read-only state preflight.
## @param ... One or more expected lineage identities.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed, nonsecret diagnostic on failure.
## @returns Nothing is written to STDOUT.
## @retval 0 Complete membership and canonical metadata are intact.
## @retval 65 Unexpected, missing, or unsafe lineage inventory.
## @note Underlying preflight failures may propagate their status.
## @par Examples
## @code
## certbotbot_bulk_verify_inventory "$config" "$probe" "example.com"
## @endcode
certbotbot_bulk_verify_inventory() {
  local config="$1" probe="$2" name
  local -A allowed=()
  local -i count=0
  shift 2
  (( $# > 0 )) || {
    printf '%s\n' 'certbotbot: empty bulk renewal inventory' >&2
    return 65
  }
  for name in "$@"; do
    [[ -z "${allowed[$name]+x}" ]] || {
      printf '%s\n' 'certbotbot: duplicate expected certificate lineage' >&2
      return 65
    }
    allowed["$name"]=1
  done
  certbotbot_state_inventory "$config" "$probe" || return $?
  (( ${#CERTBOTBOT_ARCHIVED_NAMES[@]} == $# )) || {
    printf '%s\n' 'certbotbot: archived certificate membership changed' >&2
    return 65
  }
  for name in "${CERTBOTBOT_ARCHIVED_NAMES[@]}"; do
    [[ -n "${allowed[$name]+x}" ]] || {
      printf '%s\n' 'certbotbot: unexpected archived certificate identity' >&2
      return 65
    }
    count=$((count + 1))
  done
  (( count == $# )) || return 65
  return 0
}

## @fn certbotbot_lifecycle_renew_all()
## @brief Checks every previously archived lineage once and publishes as a unit.
## @details
## This is the alternative public lifecycle for explicit RENEW_ALL=true only.
## An owned mode-0700 workspace restores the one selected authoritative S3
## object, then fully validates all original account/lineage triplets and
## canonical metadata. The original sorted inventory is frozen before ANY
## provider operation. An optional selected certificate follows ordinary
## issuance, selected renewal, or selected SAN reconciliation, and is not
## renewed again in the original archived inventory.
##
## Every remaining existing lineage uses only its own restored DNS SANs with
## certbot renew --cert-name NAME, never an unscoped renew or implicit issuance.
## State outside the currently authorized lineage is fingerprinted before and
## after EACH operation, with the complete inventory and account revalidated.
## Final certificate/key/chain verification covers every member, not only the
## selected target. Aggregate state is published once, after full success.
## Failed provider, integrity, validation, or S3 work never returns a successful
## partial result. Provider stdout/stderr and archive secrets are never echoed.
##
## A domainless invocation obtains a real archived lineage only as a read-only
## preflight and S3-publisher reference. It cannot issue certificates or alter
## any SAN set. This function owns an EXIT trap like the selected-only lifecycle.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nonsecret aggregate renewal counts and publication status on success.
## @par STDERR
## Fixed stage diagnostics without certificate DNS identities or key material.
## @returns Complete bulk renewal/no-op and publication outcome.
## @retval 0 Every authorized action completed, or all were verified no-ops.
## @retval 65 Invalid, incomplete, or unexpectedly changed account/lineage.
## @note External provider, archive, workspace, and S3 statuses propagate.
## @par Examples
## @code
## [[ "$CERTBOTBOT_RENEW_ALL" == true ]] &&
##   certbotbot_lifecycle_renew_all
## @endcode
certbotbot_lifecycle_renew_all() {
  local workspace='' config probe='' name='' account_dir='' account_before=''
  local before_state='' after_state='' other_before='' other_after=''
  local selected_state='' changed=false entry=''
  local -a original=() expected=() sans=()
  local -i checked=0 renewed=0 metadata_only=0 unchanged=0 issued=0

  workspace="$(certbotbot_workspace_create)" || return $?
  CERTBOTBOT_ACTIVE_WORKSPACE="$workspace"
  trap 'rm -rf -- "$CERTBOTBOT_ACTIVE_WORKSPACE"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ "$CERTBOTBOT_ARCHIVE_ENCRYPTION" == gpg-ocb ]]; then
    certbotbot_crypto_require "$workspace" || return $?
  fi
  certbotbot_s3_fetch "$workspace" "$CERTBOTBOT_S3_BUCKET" \
    "$CERTBOTBOT_S3_KEY" || return $?
  certbotbot_crypto_unwrap "$workspace" || return $?
  certbotbot_archive_restore "$workspace/downloaded.tar.gz" "$workspace" ||
    return $?
  config="$workspace/config"

  if [[ "$CERTBOTBOT_SELECTED_REQUEST" == true ]]; then
    probe="$CERTBOTBOT_CERT_NAME"
  fi
  certbotbot_state_inventory "$config" "$probe" || return $?
  selected_state="$CERTBOTBOT_LINEAGE_STATE"
  original=("${CERTBOTBOT_ARCHIVED_NAMES[@]}")
  expected=("${original[@]}")
  [[ -n "$probe" ]] || probe="${original[0]}"

  account_dir="$config/accounts/$CERTBOTBOT_CA_HOST/directory"
  for entry in "$account_dir/"*; do
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    account_before="${entry##*/}"
    break
  done
  [[ -n "$account_before" ]] || {
    printf '%s\n' 'certbotbot: restored ACME account is unavailable' >&2
    return 65
  }
  before_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot snapshot initial bulk certificate state' >&2
    return 74
  }

  # A malformed SAN extension is not authorized renewal input, even if it
  # belongs to a later worklist member. Check all such extensions first.
  # Expired leaves are NOT rejected here: due-renewal must be allowed to
  # replace them, and final material verification enforces nonexpiry.
  for name in "${original[@]}"; do
    certbotbot_renew_sans_read "$config/live/$name/cert.pem" || {
      printf '%s\n' 'certbotbot: unsupported archived certificate SANs' >&2
      return 65
    }
  done

  if [[ "$CERTBOTBOT_SELECTED_REQUEST" == true ]]; then
    other_before="$(certbotbot_state_unselected_fingerprint \
      "$config" "$CERTBOTBOT_CERT_NAME")" || return 65
    case "$selected_state" in
      absent)
        certbotbot_provider_issue "$workspace" "$CERTBOTBOT_CERT_NAME" \
          "${CERTBOTBOT_SANS[@]}" || return $?
        certbotbot_state_preflight "$config" "$CERTBOTBOT_CERT_NAME" ||
          return $?
        [[ "$CERTBOTBOT_LINEAGE_STATE" == present ]] || {
          printf '%s\n' 'certbotbot: newly issued bulk-selected lineage is incomplete' >&2
          return 65
        }
        certbotbot_renewal_map "$config" "$CERTBOTBOT_CERT_NAME" finalize ||
          return $?
        expected+=("$CERTBOTBOT_CERT_NAME")
        issued=1
        ;;
      present)
        certbotbot_provider_existing "$workspace" "$CERTBOTBOT_CERT_NAME" \
          "${CERTBOTBOT_SANS[@]}" || return $?
        checked=$((checked + 1))
        if [[ "$CERTBOTBOT_RENEWAL_OCCURRED" == true ]]; then
          renewed=$((renewed + 1))
        elif [[ "$CERTBOTBOT_DURABLE_CHANGED" == true ]]; then
          metadata_only=$((metadata_only + 1))
        else
          unchanged=$((unchanged + 1))
        fi
        ;;
      *)
        printf '%s\n' 'certbotbot: selected bulk lineage is ambiguous' >&2
        return 65
        ;;
    esac
    certbotbot_bulk_verify_inventory "$config" "$probe" "${expected[@]}" ||
      return $?
    other_after="$(certbotbot_state_unselected_fingerprint \
      "$config" "$CERTBOTBOT_CERT_NAME")" || return 65
    [[ "$other_before" == "$other_after" ]] || {
      printf '%s\n' 'certbotbot: selected bulk action changed unrelated state' >&2
      return 65
    }
    certbotbot_verify_material "$workspace" "$CERTBOTBOT_CERT_NAME" \
      "${CERTBOTBOT_SANS[@]}" || return $?
  fi

  # The selected preexisting lineage already received its single action.
  # A newly issued selected lineage is absent from the original worklist.
  for name in "${original[@]}"; do
    if [[ "$CERTBOTBOT_SELECTED_REQUEST" == true &&
      "$name" == "$CERTBOTBOT_CERT_NAME" ]]; then
      continue
    fi
    certbotbot_renew_sans_read "$config/live/$name/cert.pem" || {
      printf '%s\n' 'certbotbot: unsupported bulk certificate SANs' >&2
      return 65
    }
    sans=("${CERTBOTBOT_EXISTING_SANS[@]}")
    other_before="$(certbotbot_state_unselected_fingerprint \
      "$config" "$name")" || return 65
    certbotbot_provider_renew "$workspace" "$name" "${sans[@]}" || return $?
    certbotbot_bulk_verify_inventory "$config" "$probe" "${expected[@]}" ||
      return $?
    other_after="$(certbotbot_state_unselected_fingerprint \
      "$config" "$name")" || return 65
    [[ "$other_before" == "$other_after" ]] || {
      printf '%s\n' 'certbotbot: bulk renewal changed unrelated lineage state' >&2
      return 65
    }
    certbotbot_verify_material "$workspace" "$name" "${sans[@]}" ||
      return $?
    checked=$((checked + 1))
    if [[ "$CERTBOTBOT_RENEWAL_OCCURRED" == true ]]; then
      renewed=$((renewed + 1))
    elif [[ "$CERTBOTBOT_DURABLE_CHANGED" == true ]]; then
      metadata_only=$((metadata_only + 1))
    else
      unchanged=$((unchanged + 1))
    fi
  done

  if [[ ! -d "$account_dir/$account_before" ||
    -L "$account_dir/$account_before" ]]; then
    printf '%s\n' 'certbotbot: restored ACME account identity changed' >&2
    return 65
  fi
  certbotbot_bulk_verify_inventory "$config" "$probe" "${expected[@]}" ||
    return $?
  for name in "${expected[@]}"; do
    certbotbot_renew_sans_read "$config/live/$name/cert.pem" || {
      printf '%s\n' 'certbotbot: unsupported final archived certificate SANs' >&2
      return 65
    }
    sans=("${CERTBOTBOT_EXISTING_SANS[@]}")
    certbotbot_verify_material "$workspace" "$name" "${sans[@]}" ||
      return $?
  done
  after_state="$(certbotbot_renew_fingerprint "$config")" || {
    printf '%s\n' 'certbotbot: cannot inspect completed bulk certificate state' >&2
    return 74
  }
  [[ "$before_state" == "$after_state" ]] || changed=true

  certbotbot_s3_publish "$workspace" "$probe" \
    "$CERTBOTBOT_S3_BUCKET" "$CERTBOTBOT_S3_KEY" \
    "$changed" "$CERTBOTBOT_UPLOAD_NO_RENEWAL" || return $?

  # Never report complete success or even partial counts on failure.
  if [[ "$CERTBOTBOT_BACKUP_RETENTION_COUNT" != 0 ]]; then
    printf 'certbotbot: bulk checked=%d; renewed=%d; metadata-only=%d; unchanged=%d; issued=%d; published=%s; backup=%s; retention=%s; deleted=%s\n' \
      "$checked" "$renewed" "$metadata_only" "$unchanged" "$issued" \
      "$CERTBOTBOT_S3_PUBLISHED" "$CERTBOTBOT_S3_BACKUP_STATUS" \
      "$CERTBOTBOT_RETENTION_STATUS" "$CERTBOTBOT_RETENTION_DELETED"
  elif [[ "$CERTBOTBOT_DATED_BACKUP_ENABLED" == true ]]; then
    printf 'certbotbot: bulk checked=%d; renewed=%d; metadata-only=%d; unchanged=%d; issued=%d; published=%s; backup=%s\n' \
      "$checked" "$renewed" "$metadata_only" "$unchanged" "$issued" \
      "$CERTBOTBOT_S3_PUBLISHED" "$CERTBOTBOT_S3_BACKUP_STATUS"
  else
    printf 'certbotbot: bulk checked=%d; renewed=%d; metadata-only=%d; unchanged=%d; issued=%d; published=%s\n' \
      "$checked" "$renewed" "$metadata_only" "$unchanged" "$issued" \
      "$CERTBOTBOT_S3_PUBLISHED"
  fi
  return 0
}
