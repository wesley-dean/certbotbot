# shellcheck shell=bash
## @file lib/pem.bash
## @brief Validates a local Certbot lineage and prepares combined PEM files.
## @details
## Certbot's live/<lineage> entries are relative symlinks pointing to
## versioned certificate files in archive/<lineage>.  For the selected
## lineage, this module rejects any symlink whose literal target does not
## match the expected ../../archive/<name>/<kind><serial>.pem layout.
## It never extracts tar input, resolves paths provided by a consumer, or
## invokes the network.  Only regular, owned, nonempty versioned files
## are accepted.  Private key material must have no group/other access.
##
## The combined PEM format is fullchain followed by the private key.  The
## two output files are staged with restrictive modes and then renamed
## individually.  This is NOT a transaction across both paths; the producer
## must complete all local validation before any storage upload.
## @see doc/adr/ADR-019-composable-state-archives-and-consumer-boundary.md
## @see doc/adr/ADR-025-certbot-state-portability-and-issuance-boundary.md

## @fn certbotbot_pem_check_directory()
## @brief Requires an owned directory that is not group/other writable.
## @param path Absolute directory path inside a trusted producer workspace.
## @retval 0 Directory is a usable, owned, non-symlink directory.
## @retval 64 Directory is missing, unowned, symlinked, or unsafe.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_pem_check_directory() {
  local path=${1:-} mode
  if (( $# != 1 )) || [[ ${path} != /* || ! -d ${path} ||
    -L ${path} || ! -O ${path} ]]; then
    return 64
  fi
  if ! mode="$(stat -c '%a' -- "${path}")" ||
    [[ ! "${mode}" =~ ^[0-7]{3,4}$ ]] ||
    (( (8#${mode} & 8#22) != 0 )); then
    return 64
  fi
}

## @fn certbotbot_pem_check_link()
## @brief Validates one Certbot live-file link and the resolved versioned file.
## @param config_dir Owned, private Certbot configuration directory.
## @param name Canonical lineage name.
## @param kind One of cert, chain, fullchain, or privkey.
## @retval 0 Link and resolved file have the expected lineage-scoped shape.
## @retval 64 Invalid symlink, unexpected target, or missing/unowned file.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_pem_check_link() {
  local root=${1:-} name=${2:-} kind=${3:-}
  local link expected target suffix file mode
  if (( $# != 3 )) || [[ ! ${kind} =~ ^(cert|chain|fullchain|privkey)$ ]] ||
    ! certbotbot_validate_hostname "${name}" ||
    [[ ${name} == \*.* || ${name} != "${name,,}" ]]; then
    return 64
  fi

  link="${root}/live/${name}/${kind}.pem"
  if [[ ! -L "${link}" ]]; then
    return 64
  fi
  if ! target="$(readlink -- "${link}")"; then
    return 64
  fi
  expected="../../archive/${name}/${kind}"
  if [[ ${target} != "${expected}"* ]]; then
    return 64
  fi
  suffix=${target#"${expected}"}
  if [[ ! ${suffix} =~ ^[1-9][0-9]*[.]pem$ ]]; then
    return 64
  fi
  file="${root}/archive/${name}/${kind}${suffix}"
  if [[ ! -f ${file} || -L ${file} || ! -O ${file} || ! -r ${file} ||
    ! -s ${file} ]]; then
    return 64
  fi
  if [[ ${kind} == privkey ]]; then
    if ! mode="$(stat -c '%a' -- "${file}")" ||
      [[ ! ${mode} =~ ^[0-7]{3,4}$ ]] ||
      (( (8#${mode} & 8#77) != 0 )); then
      return 64
    fi
  fi
}

## @fn certbotbot_pem_assemble()
## @brief Produces two regular, private fullchain-plus-private-key PEM files.
## @details
## All four standard Certbot live symlinks must be present and valid before
## any output is written.  Existing output symlinks/special files are refused.
## Output is staged under each destination parent and renamed, with mode 0600.
## If a later local rename fails, the producer must not publish the lineage.
## This function checks local filesystem structure, not cryptographic matching
## of the certificate and its private key; the producer must also verify that
## matching relationship before publishing.
## @param config_dir Absolute existing private Certbot config directory.
## @param name Validated canonical lineage name.
## @retval 0 Both combined PEM files were assembled.
## @retval 64 Input directories, links, files, or outputs are unsafe.
## @retval 73 Local file creation, assembly, or installation failed.
## @par Standard Output
## Nothing is written to STDOUT.
certbotbot_pem_assemble() {
  local root=${1:-} name=${2:-} kind
  local archive_dir live_dir combined_dir combined_path live_path
  local combined_tmp='' live_tmp=''
  if (( $# != 2 )) || ! certbotbot_validate_hostname "${name}" ||
    [[ ${name} == \*.* || ${name} != "${name,,}" ]]; then
    return 64
  fi

  archive_dir="${root}/archive/${name}"
  live_dir="${root}/live/${name}"
  combined_dir="${root}/combined"
  combined_path="${combined_dir}/${name}.pem"
  live_path="${live_dir}/combined.pem"

  certbotbot_pem_check_directory "${root}" || return 64
  # Account keys elsewhere in the Certbot config root require full privacy.
  local root_mode
  if ! root_mode="$(stat -c '%a' -- "${root}")" ||
    (( (8#${root_mode} & 8#77) != 0 )); then
    return 64
  fi
  certbotbot_pem_check_directory "${root}/archive" || return 64
  certbotbot_pem_check_directory "${root}/live" || return 64
  certbotbot_pem_check_directory "${archive_dir}" || return 64
  certbotbot_pem_check_directory "${live_dir}" || return 64

  for kind in cert chain fullchain privkey; do
    certbotbot_pem_check_link "${root}" "${name}" "${kind}" || return 64
  done

  if [[ -e "${combined_path}" || -L "${combined_path}" ]] &&
    [[ ! -f "${combined_path}" || -L "${combined_path}" ||
      ! -O "${combined_path}" ]]; then
    return 64
  fi
  if [[ -e "${live_path}" || -L "${live_path}" ]] &&
    [[ ! -f "${live_path}" || -L "${live_path}" ||
      ! -O "${live_path}" ]]; then
    return 64
  fi

  if [[ -e ${combined_dir} || -L ${combined_dir} ]]; then
    certbotbot_pem_check_directory "${combined_dir}" || return 64
  else
    if ! mkdir -m 0700 -- "${combined_dir}"; then
      return 73
    fi
    certbotbot_pem_check_directory "${combined_dir}" || return 64
  fi

  if ! combined_tmp="$(mktemp -- "${combined_dir}/.certbotbot.XXXXXXXX")"; then
    return 73
  fi
  if ! live_tmp="$(mktemp -- "${live_dir}/.certbotbot.XXXXXXXX")"; then
    rm -f -- "${combined_tmp}"
    return 73
  fi
  if ! { cat -- "${live_dir}/fullchain.pem"; printf '\n'; cat -- "${live_dir}/privkey.pem"; } >"${combined_tmp}" ||
    ! chmod 0600 -- "${combined_tmp}" ||
    ! cat -- "${combined_tmp}" >"${live_tmp}" ||
    ! chmod 0600 -- "${live_tmp}"; then
    rm -f -- "${combined_tmp}" "${live_tmp}"
    return 73
  fi

  if ! mv -f -- "${combined_tmp}" "${combined_path}"; then
    rm -f -- "${combined_tmp}" "${live_tmp}"
    return 73
  fi
  if ! mv -f -- "${live_tmp}" "${live_path}"; then
    rm -f -- "${live_tmp}"
    return 73
  fi
}
