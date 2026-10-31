# `github-app-token`: mint a GitHub App installation token, or an organisation's
# runner registration token with one, and print it on stdout.
#
#   github-app-token --app-id 123 --key-file /run/agenix/app-key --owner Avunu \
#     [--repository name]... [--permission contents=read]... \
#     [--registration-token] [--api-url https://api.github.com]
#
# The steps are GitHub's own: sign a JWT (RS256, ten minutes) with the App's
# private key, find the App's installation on `--owner`, and ask that
# installation for a token, narrowed to the permissions and repositories given
# (none given: everything the installation was granted). An installation token
# lasts one hour. With --registration-token the installation token is spent on
# `POST /orgs/<owner>/actions/runners/registration-token` instead, and the
# registration token (also one hour) is what is printed.
#
# Nothing secret is ever an argument to another process, since argv is
# readable by every user on the machine: openssl reads the key itself, the JWT
# and the installation token reach curl as a header file on a pipe, and the
# result goes to stdout only. Callers capture it with $(...) and write it where
# it belongs; it must never reach a log. GitHub's error message is printed on
# failure, a response body never on success.
{ pkgs }:
pkgs.writeShellApplication {
  name = "github-app-token";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.curl
    pkgs.jq
    pkgs.openssl
  ];
  text = ''
    usage() {
      echo "usage: github-app-token --app-id ID --key-file PATH --owner LOGIN [--repository NAME]... [--permission NAME=LEVEL]... [--registration-token] [--api-url URL]" >&2
      exit 2
    }

    app_id=""
    key_file=""
    owner=""
    registration=0
    api_url=''${GITHUB_API_URL:-https://api.github.com}
    repositories=()
    permissions=()

    while [ $# -gt 0 ]; do
      case $1 in
        --app-id) app_id=''${2:?}; shift 2 ;;
        --key-file) key_file=''${2:?}; shift 2 ;;
        --owner) owner=''${2:?}; shift 2 ;;
        --repository) repositories+=("''${2:?}"); shift 2 ;;
        --permission) permissions+=("''${2:?}"); shift 2 ;;
        --registration-token) registration=1; shift ;;
        --api-url) api_url=''${2:?}; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$app_id" ] && [ -n "$key_file" ] && [ -n "$owner" ] || usage
    api_url=''${api_url%/}

    if [ ! -r "$key_file" ]; then
      echo "github-app-token: cannot read the private key $key_file" >&2
      exit 1
    fi

    b64url() {
      basenc --base64url -w0 | tr -d '='
    }

    # request METHOD PATH AUTHORIZATION [BODY]: the response body on stdout for a
    # 2xx status; otherwise GitHub's message on stderr and a failure. The
    # Authorization header goes to curl through a pipe, never its argv.
    request() {
      local method=$1 path=$2 auth=$3 body=''${4-} response status message
      local args=(
        --silent --show-error
        --retry 4 --retry-connrefused
        --connect-timeout 10 --max-time 60
        --request "$method"
        --header 'Accept: application/vnd.github+json'
        --header 'X-GitHub-Api-Version: 2022-11-28'
        --write-out '\n%{http_code}'
      )
      if [ -n "$body" ]; then
        args+=(--header 'Content-Type: application/json' --data-binary "$body")
      fi
      response=$(curl "''${args[@]}" --header @<(printf 'Authorization: %s\n' "$auth") "$api_url$path") || {
        echo "github-app-token: $method $path: request failed" >&2
        return 1
      }
      status=''${response##*$'\n'}
      response=''${response%$'\n'*}
      case $status in
        2??) printf '%s' "$response" ;;
        *)
          message=$(jq -r '.message // empty' <<<"$response" 2>/dev/null || true)
          echo "github-app-token: $method $path: HTTP $status''${message:+: $message}" >&2
          return 1
          ;;
      esac
    }

    # The App's JWT. Issued a minute in the past and valid for nine more, which
    # is GitHub's advice for a clock that is slightly off.
    now=$(date +%s)
    header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
    payload=$(jq -cjn --argjson iat $((now - 60)) --argjson exp $((now + 540)) --arg iss "$app_id" \
      '{iat: $iat, exp: $exp, iss: $iss}' | b64url)
    signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -binary -sign "$key_file" | b64url)
    jwt="$header.$payload.$signature"

    installations=$(request GET "/app/installations?per_page=100" "Bearer $jwt")
    installation=$(jq -r --arg owner "$owner" \
      'first(.[] | select((.account.login | ascii_downcase) == ($owner | ascii_downcase))) | .id' \
      <<<"$installations")
    if [ -z "$installation" ] || [ "$installation" = null ]; then
      echo "github-app-token: App $app_id is not installed on $owner" >&2
      exit 1
    fi

    # Narrowing. No permissions means all of the installation's; no
    # repositories means all of the repositories it can see.
    perms_json=$(printf '%s\n' "''${permissions[@]}" \
      | jq -Rn '[inputs | select(length > 0) | capture("^(?<k>[a-z_]+)=(?<v>[a-z]+)$") | {(.k): .v}] | add // {}')
    repos_json=$(printf '%s\n' "''${repositories[@]}" | jq -Rn '[inputs | select(length > 0)]')
    body=$(jq -cn --argjson p "$perms_json" --argjson r "$repos_json" \
      '(if ($p | length) > 0 then {permissions: $p} else {} end)
       + (if ($r | length) > 0 then {repositories: $r} else {} end)')

    token=$(request POST "/app/installations/$installation/access_tokens" "Bearer $jwt" "$body" | jq -r '.token // empty')
    if [ -z "$token" ]; then
      echo "github-app-token: GitHub returned no installation token for $owner" >&2
      exit 1
    fi

    if [ "$registration" = 1 ]; then
      token=$(request POST "/orgs/$owner/actions/runners/registration-token" "token $token" | jq -r '.token // empty')
      if [ -z "$token" ]; then
        echo "github-app-token: GitHub returned no runner registration token for $owner" >&2
        exit 1
      fi
    fi

    printf '%s\n' "$token"
  '';
}
