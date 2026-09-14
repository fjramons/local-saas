# --- 'saas minio bucket create|list|rm': lets MinIO be used as general-purpose object storage, not
# just a backend other services integrate with. Runs the pinned quay.io/minio/mc image as a
# throwaway pod ('kubectl run --rm -i'), never on the host: this repo's mc invocations always stay
# inside that container, so they never collide with a host-installed 'mc' (Midnight Commander on
# many systems, this dev machine included). See README.md/CLAUDE.md for the equivalent host-facing
# naming note ('mcli', not 'mc') for anyone talking to the exposed S3 endpoint directly.

# _saas_minio_mc_run NAMESPACE RELEASE ROOT_USER ROOT_PASSWORD MC_ARGS...
# Runs one 'mc' command against RELEASE's in-cluster S3 endpoint. Output streams straight back
# (kubectl run --rm -i), no log-fetching needed, which is what makes this a good fit for 'bucket
# list' too, not just 'create'/'rm'.
_saas_minio_mc_run() {
    local ns="$1" release="$2" root_user="$3" root_password="$4"; shift 4
    local mc_cmd="$*"
    # --command is required: the pinned image's own ENTRYPOINT is ["mc"], so 'kubectl run ... --
    # sh -c ...' without it would run 'mc sh -c ...' (mc trying, and failing, to interpret 'sh' as
    # one of its own subcommands) instead of actually invoking a shell. --command replaces the
    # entrypoint outright, verified live against the real image.
    #
    # 'sleep 1' before the real command is a verified-live workaround for a real 'kubectl run --rm
    # -i' attach race: for a command that produces output almost immediately, kubectl's attach can
    # still be latching onto the container's stdout stream when the container already finished
    # writing it, silently losing that output (reproduced live, 3/3 runs, with 'mc ls local' right
    # after 'mc alias set': completely empty output every time without the sleep, the real listing
    # every time with it). The pod's own exit code isn't affected either way, only what actually
    # gets displayed - since 'bucket list's whole point IS the displayed output, this isn't optional.
    kubectl -n "$ns" run "${release}-mc-$$" --rm -i --restart=Never \
        --image="$_SAAS_MC_IMAGE" --quiet --command -- sh -c \
        "mc alias set local http://${release}.${ns}.svc.cluster.local:9000 '${root_user}' '${root_password}' >/dev/null && sleep 1 && ${mc_cmd}"
}

_saas_minio_bucket_help() {
    cat <<'EOF'
Usage: saas minio bucket SUBCOMMAND [OPTIONS]

Manage buckets on a 'saas minio' release.

Subcommands:
  create NAME    Create a bucket (idempotent: no error if it already exists)
  list           List all buckets
  rm NAME        Remove a bucket

Options (all subcommands):
      --release NAME   The minio release (default: suggested if only one exists)
  -h, --help            Show this help

Options (rm only):
      --force            Remove the bucket even if it isn't empty

Examples:
  saas minio bucket create my-bucket
  saas minio bucket list
  saas minio bucket rm my-bucket --force
EOF
}

_saas_minio_bucket_create() {
    local release="" name="" args
    args=$(getopt -o h -l release:,help --name saas_minio_bucket_create -- "$@") || { _saas_minio_bucket_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            -h|--help) _saas_minio_bucket_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    name="${1:-}"
    [ -n "$name" ] || { _saas_log_err "Usage: saas minio bucket create NAME [--release RELEASE]"; return 1; }
    _saas_minio_valid_bucket_name "$name" || { _saas_log_err "'$name' isn't a valid S3 bucket name (lowercase letters/digits/hyphens/dots, 3-63 chars, must start/end with a letter or digit)."; return 1; }
    [ -n "$release" ] || release="$(_saas_minio_suggest_release)"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    _saas_minio_mc_run "$SAAS_MINIO_STATE_NAMESPACE" "$SAAS_MINIO_STATE_RELEASE" \
        "$SAAS_MINIO_STATE_ROOT_USER" "$SAAS_MINIO_STATE_ROOT_PASSWORD" \
        "mc mb --ignore-existing 'local/${name}'" \
        && _saas_log_ok "Bucket '$name' ready."
}

_saas_minio_bucket_list() {
    local release="" args
    args=$(getopt -o h -l release:,help --name saas_minio_bucket_list -- "$@") || { _saas_minio_bucket_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            -h|--help) _saas_minio_bucket_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    [ -n "$release" ] || release="$(_saas_minio_suggest_release)"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    _saas_minio_mc_run "$SAAS_MINIO_STATE_NAMESPACE" "$SAAS_MINIO_STATE_RELEASE" \
        "$SAAS_MINIO_STATE_ROOT_USER" "$SAAS_MINIO_STATE_ROOT_PASSWORD" \
        "mc ls local"
}

_saas_minio_bucket_rm() {
    local release="" name="" force=false args
    args=$(getopt -o h -l release:,force,help --name saas_minio_bucket_rm -- "$@") || { _saas_minio_bucket_help; return 1; }
    eval set -- "$args"
    while true; do
        case "$1" in
            --release) release="$2"; shift 2 ;;
            --force)   force=true; shift ;;
            -h|--help) _saas_minio_bucket_help; return 0 ;;
            --) shift; break ;;
        esac
    done
    name="${1:-}"
    [ -n "$name" ] || { _saas_log_err "Usage: saas minio bucket rm NAME [--release RELEASE] [--force]"; return 1; }
    [ -n "$release" ] || release="$(_saas_minio_suggest_release)"

    _saas_minio_state_load "$release" || { _saas_log_err "No saved state for release '$release'."; return 1; }
    local force_flag=""
    $force && force_flag="--force"
    _saas_minio_mc_run "$SAAS_MINIO_STATE_NAMESPACE" "$SAAS_MINIO_STATE_RELEASE" \
        "$SAAS_MINIO_STATE_ROOT_USER" "$SAAS_MINIO_STATE_ROOT_PASSWORD" \
        "mc rb $force_flag 'local/${name}'" \
        && _saas_log_ok "Bucket '$name' removed."
}

_saas_minio_bucket() {
    local subcommand="${1:-}"
    [ $# -gt 0 ] && shift
    case "$subcommand" in
        create)      _saas_minio_bucket_create "$@" ;;
        list)        _saas_minio_bucket_list "$@" ;;
        rm)          _saas_minio_bucket_rm "$@" ;;
        ""|-h|--help|help)
            _saas_minio_bucket_help
            ;;
        *)
            _saas_log_err "Unknown subcommand: 'bucket ${subcommand}'"
            _saas_minio_bucket_help >&2
            return 1
            ;;
    esac
}
