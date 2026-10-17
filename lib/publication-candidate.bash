# shellcheck shell=bash
## @file lib/publication-candidate.bash
## @brief Freezes and verifies a complete local publication candidate.
## @details
## ADR-042 permits preparation of an immutable, owner-private set of common
## and domain objects while prohibiting remote mutation. Every selected
## lineage must pass isolated archive import assessment, cryptographic chain
## and key checks, and exact requested DNS SAN matching before the candidate
## becomes visible to its caller. The selected GPG format applies to every
## object. No archive is uploaded by this module.
## @see doc/adr/ADR-042-local-publication-candidate-gate.md

## @var CERTBOTBOT_PUBLICATION_ROOT
## @brief Owner-private candidate staging directory on success.
CERTBOTBOT_PUBLICATION_ROOT=''

## @var CERTBOTBOT_PUBLICATION_KEYS
## @brief Ordered S3 latest-object keys; common first, then selected domains.
declare -a CERTBOTBOT_PUBLICATION_KEYS=()

## @var CERTBOTBOT_PUBLICATION_FILES
## @brief Matching frozen local files, plaintext or AES-256 ciphertext.
declare -a CERTBOTBOT_PUBLICATION_FILES=()

## @fn certbotbot_publication_discard()
## @brief Disposes of this invocation's recorded publication candidate.
## @retval 0 Nothing owned, or candidate successfully discarded.
## @retval 73 Unsafe recorded private directory or failed deletion.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_publication_discard() {
  local root=${CERTBOTBOT_PUBLICATION_ROOT:-} mode=''
  [[ -n $root ]] || return 0
  if [[ -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
    $root != "$CERTBOTBOT_WORKSPACE_ROOT"/publication.???????? ||
    ! ${root##*/} =~ ^publication[.][a-zA-Z0-9]{8}$ ||
    ! -d $root || -L $root || ! -O $root ]]; then
    return 73
  fi
  mode="$(stat -c '%a' -- "$root")" || return 73
  [[ $mode == 700 ]] || return 73
  rm -rf -- "$root" || return 73
  CERTBOTBOT_PUBLICATION_ROOT=''
  # Values are part of the standalone artifact's caller-facing contract.
  # shellcheck disable=SC2034
  CERTBOTBOT_PUBLICATION_KEYS=()
  # shellcheck disable=SC2034
  CERTBOTBOT_PUBLICATION_FILES=()
}

## @fn certbotbot_publication_prepare()
## @brief Verify a complete set of portable certificate archives for publication.
## @details
## The input is a bucket, optional trust anchor (empty uses host trust),
## one common account tarball, and explicit name/archive/SAN-list triples.
## SAN lists are comma-separated canonical DNS identities, for example
## example.com,*.example.com. They are data, never parsed as shell source.
## All archive inputs are frozen before validation and no destination key is
## derived from an unvalidated name. The live Certbot configuration remains
## empty. A successful candidate must be explicitly discarded by the caller;
## later authorization and remote publication need a separate reviewed gate.
##
## @param bucket Reviewed S3 bucket identity.
## @param common_archive Absolute common account tar.gz path.
## @param ca_bundle Trusted CA file, or empty for host defaults.
## @param ... One or more (name, domain_tar_gz, comma_separated_sans) triples.
## @retval 0 Complete frozen private candidate with ordered object keys/files.
## @retval 64 Invalid requests or rejected structural/certificate inputs.
## @retval 65 Invalid account association, X.509 state, or SAN identity.
## @retval 69 Missing GPG/OpenSSL or other runtime dependency.
## @retval 73 Local staging, copying, or cleanup failed.
## @note Sub-validator failures propagate their documented error statuses.
## @par STDIN
## Nothing is read from STDIN.
## @returns Nothing is written to STDOUT.
certbotbot_publication_prepare() {
  local bucket=${1:-} common=${2:-} ca_bundle=${3:-}
  local environment=${ACME_ENVIRONMENT:-production} suffix=''
  local root='' file='' name='' sans_text='' domain='' result=0 index=0
  local saved='' key='' cipher='' original='' kind=''
  local -a triples=() pairs=() frozen=() keys=() outputs=() sans=()
  local -A names=() paths=()

  # The entire producer must be in one mode, and tracing must be rejected
  # before accessing the optional symmetric archive secret.
  if (( $# < 6 || ($# - 3) % 3 != 0 || $# > 99 )) ||
    [[ $- == *x* ||
      -n ${CERTBOTBOT_PUBLICATION_ROOT:-} ||
      -n ${CERTBOTBOT_COMMON_STAGE:-} ||
      -n ${CERTBOTBOT_RESTORE_ROOT:-} ||
      -n ${CERTBOTBOT_RENEWAL_PREVIEW:-} ||
      -n ${CERTBOTBOT_S3_STAGE_ROOT:-} ||
      $common != /* || ! -f $common || -L $common ||
      ! -O $common || ! -r $common ||
      -z ${CERTBOTBOT_WORKSPACE_ROOT:-} ||
      -z ${CERTBOTBOT_WORKSPACE_CONFIG:-} ]] ||
    ! certbotbot_acme_validate_environment "$environment"; then
    return 64
  fi
  if [[ -n ${GPG_PASSPHRASE:-} ]]; then
    [[ $GPG_PASSPHRASE != *[[:cntrl:]]* ]] || return 64
    suffix=.enc
  fi

  if [[ ! -d $CERTBOTBOT_WORKSPACE_ROOT ||
    -L $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -O $CERTBOTBOT_WORKSPACE_ROOT ||
    ! -d $CERTBOTBOT_WORKSPACE_CONFIG ||
    -L $CERTBOTBOT_WORKSPACE_CONFIG ||
    ! -O $CERTBOTBOT_WORKSPACE_CONFIG ]] ||
    [[ "$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_ROOT")" != 700 ||
      "$(stat -c '%a' -- "$CERTBOTBOT_WORKSPACE_CONFIG")" != 700 ]]; then
    return 64
  fi
  if [[ -n "$(find -P "$CERTBOTBOT_WORKSPACE_CONFIG" \
    -mindepth 1 -print -quit)" ]]; then
    return 64
  fi
  if [[ -n $ca_bundle &&
    ( $ca_bundle != /* || ! -f $ca_bundle || -L $ca_bundle ||
      ! -r $ca_bundle ) ]]; then
    return 64
  fi
  triples=("${@:4}")
  key="$(certbotbot_acme_object_key "$environment" \
    "common-latest.tar.gz$suffix")" || return 64
  certbotbot_storage_s3_validate_target "$bucket" "$key" || return 64
  keys+=("$key")
  for (( index=0; index<${#triples[@]}; index+=3 )); do
    name=${triples[index]}
    domain=${triples[index+1]}
    sans_text=${triples[index+2]}
    if ! certbotbot_validate_hostname "$name" ||
      [[ $name == \*.* || $name != "${name,,}" ||
        $domain != /* || ! -f $domain || -L $domain ||
        ! -O $domain || ! -r $domain ||
        $domain == "$common" ||
        -z $sans_text || $sans_text == ,* ||
        $sans_text == *, || $sans_text == *,,* ||
        -n ${names[$name]+_} ||
        -n ${paths[$domain]+_} ]]; then
      return 64
    fi
    # The downstream exact-SAN verifier is the final authority; preflight
    # also rejects unsafe identifiers before allocating a candidate.
    IFS=, read -r -a sans <<<"$sans_text"
    for kind in "${sans[@]}"; do
      certbotbot_validate_hostname "$kind" || return 64
      [[ $kind == "${kind,,}" ]] || return 64
    done
    names["$name"]=1
    paths["$domain"]=1
    key="$(certbotbot_acme_object_key "$environment" \
      "$name-latest.tar.gz$suffix")" || return 64
    certbotbot_storage_s3_validate_target "$bucket" "$key" || return 64
    keys+=("$key")
  done

  root="$(mktemp -d -- \
    "$CERTBOTBOT_WORKSPACE_ROOT/publication.XXXXXXXX")" || return 73
  CERTBOTBOT_PUBLICATION_ROOT=$root

  # Make one private frozen copy of every archive; the caller's original
  # paths cannot silently change the bytes subsequently prepared.
  saved="$(mktemp -- "$root/object.XXXXXXXX")" || result=73
  if (( result == 0 )); then
    if (umask 077; cp -- "$common" "$saved" &&
      chmod 0600 -- "$saved"); then
      frozen+=("$saved")
    else
      result=73
    fi
  fi
  if (( result == 0 )); then
    for (( index=0; index<${#triples[@]}; index+=3 )); do
      saved="$(mktemp -- "$root/object.XXXXXXXX")" || {
        result=73
        break
      }
      if ! (umask 077; cp -- "${triples[index+1]}" "$saved" &&
        chmod 0600 -- "$saved"); then
        result=73
        break
      fi
      frozen+=("$saved")
      pairs+=("${triples[index]}" "$saved")
    done
  fi

  if (( result == 0 )); then
    certbotbot_import_assess_batch "${frozen[0]}" "$environment" \
      "${pairs[@]}" || result=$?
  fi

  # Static archive/identity checks are not sufficient for deployable
  # certificates: verify trust, key match, combined PEM, and exact SANs.
  if (( result == 0 )); then
    for (( index=0; index<${#triples[@]}; index+=3 )); do
      name=${triples[index]}
      sans_text=${triples[index+2]}
      IFS=, read -r -a sans <<<"$sans_text"
      if certbotbot_restore_domain \
        "${frozen[index/3+1]}" "$name"; then
        certbotbot_crypto_verify_lineage "$CERTBOTBOT_RESTORE_ROOT" \
          "$name" "$ca_bundle" || result=$?
        if (( result == 0 )); then
          certbotbot_crypto_verify_sans "$CERTBOTBOT_RESTORE_ROOT" \
            "$name" "${sans[@]}" || result=$?
        fi
        certbotbot_restore_discard || result=73
      else
        result=$?
      fi
      (( result == 0 )) || break
    done
  fi

  if (( result == 0 )); then
    for file in "${frozen[@]}"; do
      if [[ -n $suffix ]]; then
        cipher="$(mktemp -- "$root/object.XXXXXXXX")" || {
          result=73
          break
        }
        if certbotbot_gpg_encrypt_archive "$file" "$cipher"; then
          outputs+=("$cipher")
        else
          result=$?
          break
        fi
      else
        outputs+=("$file")
      fi
    done
  fi

  if (( result != 0 )); then
    certbotbot_publication_discard || return 73
    return "$result"
  fi
  # The approved object-key order is common first. No AWS put is called.
  CERTBOTBOT_PUBLICATION_KEYS=("${keys[@]}")
  # shellcheck disable=SC2034
  CERTBOTBOT_PUBLICATION_FILES=("${outputs[@]}")
  return 0
}
