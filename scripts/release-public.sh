#!/bin/zsh
# Copies the current commit to a separate public repository as one new commit (no private history),
# tagged with the version. Configure in config.local.env:
#   PUBLIC_REPO="owner/name"                 GitHub repository to publish to
#   PUBLIC_AUTHOR="Name <email>"             optional; the commit author (default: your git identity)
# Refuses to publish if any value from config.local.env appears in the files, or the tree isn't committed.
# Usage: scripts/release-public.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f config.local.env ]] && source config.local.env
: "${PUBLIC_REPO:?Set PUBLIC_REPO in config.local.env}"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit your changes first." >&2; exit 1; }

VERSION=$(cat VERSION)
SUBJECT=$(git log -1 --format=%s)
BODY=$(git log -1 --format=%b | grep -v '^Co-Authored-By:' || true)
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

gh repo clone "$PUBLIC_REPO" "$WORK/repo" -- -q
git -C "$WORK/repo" rm -rq --ignore-unmatch . >/dev/null
git archive HEAD | tar -x -C "$WORK/repo"

# Privacy guard: nothing from your local settings may be published.
if [[ -f config.local.env ]]; then
  for value in $(grep -E '^[A-Z_]+=' config.local.env | grep -v '^PUBLIC_' | cut -d= -f2- | tr -d '"' | tr ' ' '\n'); do
    [[ ${#value} -ge 6 ]] || continue
    if grep -rIlF -- "$value" "$WORK/repo" --exclude-dir=.git >/dev/null; then
      echo "Refusing to publish: \"$value\" from config.local.env appears in:" >&2
      grep -rIlF -- "$value" "$WORK/repo" --exclude-dir=.git >&2
      exit 1
    fi
  done
fi

cd "$WORK/repo"
git add -A
if git diff --cached --quiet; then echo "Nothing new to publish."; exit 0; fi
AUTHOR="${PUBLIC_AUTHOR:-$(git -C "$OLDPWD" config user.name) <$(git -C "$OLDPWD" config user.email)>}"
export GIT_AUTHOR_NAME="${AUTHOR% <*}" GIT_AUTHOR_EMAIL="${${AUTHOR##*<}%>}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
if git rev-parse -q --verify HEAD >/dev/null; then
  git commit -q -m "$SUBJECT" ${BODY:+-m "$BODY"}
else
  git commit -q -m "Un-remarkable for Mac v$VERSION" -m "First public release. See README.md to build it and connect your reMarkable."
fi
git tag -f "v$VERSION" >/dev/null
git push -q origin HEAD
git push -q -f origin "v$VERSION"
echo "Published v$VERSION to https://github.com/$PUBLIC_REPO"
