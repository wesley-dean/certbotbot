# shellcheck shell=bash
## @file lib/archive-validate.bash
## @brief Performs strict pre-extraction validation of one Certbot domain tarball.
## @details
## The validator does not extract data, access the network, or modify the
## certificate workspace.  It accepts only a bounded, lineage-specific GNU
## tar manifest with regular files, directories, and the four expected relative
## Certbot live symlinks.  Hard links, devices, FIFOs, absolute/traversal paths,
## unknown members, and duplicate names are rejected before extraction.
##
## The metadata representation is pinned to GNU tar --full-time,
## --numeric-owner, and --quoting-style=escape.  Unexpected filenames,
## quoting, or formatting fail closed rather than being guessed.  This
## preflight alone does not make later tar extraction safe: the producer must
## also extract only into a freshly owned private directory, protect against
## filesystem races, and verify extracted file content and renewal metadata.
## @see doc/adr/ADR-019-composable-state-archives-and-consumer-boundary.md
## @see doc/adr/ADR-026-validated-domain-archive-manifests.md

## @fn certbotbot_archive_validate_domain()
## @brief Validates one local compressed domain archive without extracting it.
## @param archive Absolute, owned, readable .tar.gz file.
## @param name Canonical lineage identity, without a leading wildcard.
## @retval 0 All members have approved paths, types, links, and size limits.
## @retval 64 Invalid arguments or nonconforming archive contents.
## @retval 69 GNU tar listing is unavailable or failed.
## @par Standard Output
## Nothing is written to STDOUT.
## @note No file is extracted or installed by this function.
certbotbot_archive_validate_domain() {
  local LC_ALL=C
  local archive=${1:-} name=${2:-}
  local manifest line mode type path target size_text size count=0 total=0
  local serial kind remainder expected
  local -A seen=() members=() live_targets=()
  local -a kinds=(cert chain fullchain privkey)

  if (( $# != 2 )) || [[ ${archive} != /* || ! -f ${archive} ||
    -L ${archive} || ! -O ${archive} || ! -r ${archive} ]] ||
    ! certbotbot_validate_hostname "${name}" ||
    [[ ${name} == \*.* || ${name} != "${name,,}" ]]; then
    printf '%s\n' 'invalid domain archive validation request' >&2
    return 64
  fi

  if ! command -v tar >/dev/null 2>&1; then
    printf '%s\n' 'GNU tar is required for archive inspection' >&2
    return 69
  fi

  # Listing is a metadata-only operation.  Using a bounded member policy
  # does not eliminate compressed-stream resource exhaustion; see ADR-026.
  if ! manifest="$(tar --list --gzip --verbose --file "${archive}" \
    --full-time --numeric-owner --quoting-style=escape)"; then
    printf '%s\n' 'cannot read the certificate archive manifest' >&2
    return 69
  fi

  if [[ -z ${manifest} ]]; then
    printf '%s\n' 'empty certificate archive manifest' >&2
    return 64
  fi

  while IFS= read -r line || [[ -n ${line} ]]; do
    (( count += 1 ))
    if (( count > 4096 )) ||
      [[ ! ${line} =~ ^([-dl][rwxstST-]{9})[[:space:]]+[0-9]+/[0-9]+[[:space:]]+([0-9]+)[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]+(.+)$ ]]; then
      printf '%s\n' 'unsupported archive metadata or member count' >&2
      return 64
    fi

    mode=${BASH_REMATCH[1]}
    size_text=${BASH_REMATCH[2]}
    remainder=${BASH_REMATCH[3]}
    type=${mode:0:1}

    # Bound each regular file and total uncompressed payload.  Reject
    # extremely large decimal metadata before arithmetic conversion.
    if [[ ! ${size_text} =~ ^[0-9]{1,9}$ ]]; then
      return 64
    fi
    size=$((10#${size_text}))
    if (( size > 8388608 )); then
      return 64
    fi
    total=$((total + size))
    if (( total > 67108864 )); then
      return 64
    fi

    if [[ ${type} == l ]]; then
      if [[ ! ${remainder} =~ ^([^[:space:]]+)[[:space:]]+->[[:space:]]+([^[:space:]]+)$ ]]; then
        return 64
      fi
      path=${BASH_REMATCH[1]}
      target=${BASH_REMATCH[2]}
      if (( size != 0 )); then
        return 64
      fi
    else
      path=${remainder}
      target=''
    fi

    if [[ -n ${seen[${path}]+_} ]] ||
      [[ ${path} == *\\* || ${path} == /* || ${path} == ./* ||
        ${path} == *../* || ${path} == *'/./'* ]]; then
      printf '%s\n' 'duplicate or unsafe archive member' >&2
      return 64
    fi
    seen["${path}"]=1

    case "${type}" in
      d)
        if (( size != 0 )) ||
          [[ ${path} != archive/ && ${path} != "archive/${name}/" &&
            ${path} != live/ && ${path} != "live/${name}/" &&
            ${path} != renewal/ && ${path} != combined/ ]]; then
          return 64
        fi
        ;;
      -)
        if (( size == 0 )) || [[ ! ${path} =~ ^[a-z0-9./_-]+$ ]]; then
          return 64
        fi
        if [[ ${path} == "archive/${name}/"* ]]; then
          remainder=${path#"archive/${name}/"}
          if [[ ! ${remainder} =~ ^(cert|chain|fullchain|privkey)[1-9][0-9]*[.]pem$ ]]; then
            return 64
          fi
          kind=${BASH_REMATCH[1]}
        elif [[ ${path} == "renewal/${name}.conf" ]]; then
          kind=renewal
        elif [[ ${path} == "live/${name}/combined.pem" ||
          ${path} == "combined/${name}.pem" ]]; then
          kind=combined
        else
          return 64
        fi
        if [[ ${kind} == privkey || ${kind} == combined ]] &&
          [[ ${mode:4:6} != ------ ]]; then
          return 64
        fi
        members["${path}"]=1
        ;;
      l)
        if [[ ${path} != "live/${name}/"* ]]; then
          return 64
        fi
        remainder=${path#"live/${name}/"}
        if [[ ! ${remainder} =~ ^(cert|chain|fullchain|privkey)[.]pem$ ]]; then
          return 64
        fi
        kind=${BASH_REMATCH[1]}
        expected="../../archive/${name}/${kind}"
        if [[ ${target} != "${expected}"* ]]; then
          return 64
        fi
        serial=${target#"${expected}"}
        if [[ ! ${serial} =~ ^[1-9][0-9]*[.]pem$ ]]; then
          return 64
        fi
        live_targets["${kind}"]="archive/${name}/${kind}${serial}"
        ;;
      *)
        return 64
        ;;
    esac
  done <<< "${manifest}"

  for kind in "${kinds[@]}"; do
    if [[ -z ${live_targets[${kind}]+_} ||
      -z ${members[${live_targets[${kind}]}]+_} ]]; then
      printf '%s\n' 'incomplete Certbot lineage in domain archive' >&2
      return 64
    fi
  done

  if [[ -z ${members["renewal/${name}.conf"]+_} ||
    -z ${members["live/${name}/combined.pem"]+_} ||
    -z ${members["combined/${name}.pem"]+_} ]]; then
    printf '%s\n' 'required domain archive members are missing' >&2
    return 64
  fi
  return 0
}
