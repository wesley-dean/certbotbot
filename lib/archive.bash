#!/usr/bin/env bash
# shellcheck shell=bash
## @file lib/archive.bash
## @brief Performs bounded, pre-extraction gzip/tar header validation.
## @details
## This module enforces the initial supported format subset in ADR-022.
## It does not extract members, validate ACME account identity, interpret
## renewal hooks, or authorize Certbot execution. Unsupported tar extensions
## are rejected rather than reinterpreted or silently accepted.

## @fn certbotbot_archive_validate()
## @brief Checks one staged archive for supported, safe tar structure.
## @details
## The gzip stream is expanded to a private temporary file, with a 32 MiB
## hard expansion limit. Header bytes are read with od and inspected with awk:
## octal metadata, checksums, canonical member names, types, owner/mode
## constraints, duplicate paths, parent types, and expected live PEM symlinks.
## No archive contents are activated or echoed. The caller must separately
## validate account, lineage, hooks, and path mapping before any extraction.
## @param archive Readable regular file containing the S3 archive.
## @par STDIN
## Nothing is read from STDIN.
## @par STDOUT
## Nothing is written to STDOUT.
## @par STDERR
## Fixed diagnostics without untrusted member names or bytes.
## @returns Nothing is written to STDOUT.
## @retval 0 Supported archive preflight completed successfully.
## @retval 64 Caller supplied an unreadable or unsafe archive input.
## @retval 65 Archive is malformed, oversized, or unsupported.
## @par Examples
## @code
## certbotbot_archive_validate "$workspace/downloaded.tar.gz" || exit $?
## # Do not extract or run Certbot based on format validation alone.
## @endcode
certbotbot_archive_validate() {
  umask 077
  local archive temp decoded length
  if (( $# != 1 )); then
    printf '%s\n' 'certbotbot: invalid archive input' >&2
    return 64
  fi
  archive="$1"
  if [[ ! -f "$archive" || ! -r "$archive" || -L "$archive" ]]; then
    printf '%s\n' 'certbotbot: unreadable archive input' >&2
    return 64
  fi
  if ! command -v gzip >/dev/null 2>&1 ||
    ! command -v od >/dev/null 2>&1 ||
    ! command -v awk >/dev/null 2>&1; then
    printf '%s\n' 'certbotbot: archive validation tools unavailable' >&2
    return 65
  fi
  temp="$(mktemp -d)" || {
    printf '%s\n' 'certbotbot: private archive staging failed' >&2
    return 65
  }
  decoded="$temp/decoded.tar"
  if ! (set -o pipefail; gzip -cd -- "$archive" 2>/dev/null |
    head -c 33554433 >"$decoded"); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: invalid or oversized archive' >&2
    return 65
  fi
  length="$(wc -c <"$decoded")" || { rm -rf -- "$temp"; return 65; }
  if (( length < 1024 || length > 33554432 || length % 512 != 0 )); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: invalid archive boundaries' >&2
    return 65
  fi
  if ! (set -o pipefail; LC_ALL=C od -An -v -tu1 -w512 -- "$decoded" |
    LC_ALL=C awk -f /dev/fd/3 3<<'CERTBOTBOT_ARCHIVE_AWK'
    function reject() { invalid=1; exit 1 }
    function field(start,width,  i,x,s,ended) {
      s=""; ended=0
      for(i=start;i<start+width;i++){
        x=b[i]
        if(x==0){ended=1;continue}
        if(ended || x<32 || x>126) reject()
        s=s sprintf("%c",x)
      }
      return s
    }
    function octal(start,width,  i,x,v,ended) {
      v=0;ended=0
      for(i=start;i<start+width;i++){
        x=b[i]
        if(x==0 || x==32){ended=1;continue}
        if(ended || x<48 || x>55) reject()
        v=v*8+(x-48)
      }
      return v
    }
    function canonical(path,kind,  a,n,i) {
      if(path=="./" && kind==53)return "."
      if(path ~ /^\.\//)path=substr(path,3)
      if(kind==53 && path ~ /\/$/)path=substr(path,1,length(path)-1)
      if(path=="" || path ~ /^\// || path ~ /\/\// ||
        path !~ /^[A-Za-z0-9._\/-]+$/)reject()
      n=split(path,a,"/")
      for(i=1;i<=n;i++)if(a[i]=="" || a[i]=="." || a[i]=="..")reject()
      if(a[1]!="accounts" && a[1]!="archive" && a[1]!="live" &&
        a[1]!="renewal" && a[1]!="csr" && a[1]!="keys" &&
        a[1]!="README" && a[1]!="cli.ini" &&
        a[1]!="renewal-hooks")reject()
      if(a[1]=="renewal-hooks" && kind!=53)reject()
      if((a[1]=="README" || a[1]=="cli.ini") && n!=1)reject()
      return path
    }
    function link_target(path,link,  p,t,n,m,base,prefix) {
      n=split(path,p,"/");m=split(link,t,"/")
      if(n!=3 || p[1]!="live" ||
        p[3] !~ /^(cert|chain|fullchain|privkey)\.pem$/)reject()
      if(m!=5 || t[1]!=".." || t[2]!=".." || t[3]!="archive" ||
        t[4]!=p[2] ||
        t[5] !~ /^(cert|chain|fullchain|privkey)[1-9][0-9]*\.pem$/)reject()
      prefix=p[3];sub(/\.pem$/,"",prefix)
      base=t[5];sub(/[1-9][0-9]*\.pem$/,"",base)
      if(prefix!=base)reject()
      return "archive/" t[4] "/" t[5]
    }
    {
      if(NF!=512)reject()
      for(i=1;i<=512;i++)b[i]=$i+0
      if(skip>0){skip--;next}
      empty=1
      for(i=1;i<=512;i++)if(b[i]!=0){empty=0;break}
      if(empty){zeros++;next}
      if(zeros>0)reject()
      count++
      if(count>2048)reject()
      if(b[258]!=117 || b[259]!=115 || b[260]!=116 ||
        b[261]!=97 || b[262]!=114)reject()
      if(!((b[263]==0 && b[264]==48 && b[265]==48) ||
        (b[263]==32 && b[264]==32)))reject()
      total=0
      for(i=1;i<=512;i++)total+=((i>=149 && i<=156)?32:b[i])
      if(octal(149,8)!=total)reject()
      size=octal(125,12);mode=octal(101,8)
      if(size>33554432 || mode>=512 ||
        int(mode/16)%2!=0 || int(mode/2)%2!=0 ||
        octal(109,8)>65535 || octal(117,8)>65535)reject()
      kind=b[157]
      if(kind!=0 && kind!=48 && kind!=53 && kind!=50)reject()
      path=field(1,100)
      prefix=field(346,155)
      if(prefix!=""){
        if(b[263]!=0)reject()
        path=prefix "/" path
      }
      path=canonical(path,kind)
      if(seen[path]++)reject()
      types[path]=kind
      link=field(158,100)
      if(kind==53){
        if(size!=0 || link!="")reject()
      } else if(kind==50){
        if(size!=0)reject()
        targets[path]=link_target(path,link)
      } else if(link!="")reject()
      skip=int((size+511)/512)
    }
    END {
      if(invalid || count==0 || zeros<2 || skip>0)exit 1
      for(path in types){
        n=split(path,part,"/");parent=""
        for(i=1;i<n;i++){
          parent=(parent==""?part[i]:parent "/" part[i])
          if((parent in types) && types[parent]!=53)exit 1
        }
      }
      for(path in targets){
        target=targets[path]
        if(!(target in types) || (types[target]!=0 && types[target]!=48))
          exit 1
      }
    }
CERTBOTBOT_ARCHIVE_AWK
  ); then
    rm -rf -- "$temp"
    printf '%s\n' 'certbotbot: unsafe or unsupported archive contents' >&2
    return 65
  fi
  rm -rf -- "$temp"
  return 0
}