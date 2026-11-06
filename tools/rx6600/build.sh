#!/usr/bin/env bash
# RX 6600 / Debian 13: staged, reproducible Lichii integration build (v2).
# Base: zortos293/Lichii nx2 28d99d3 (already includes AMD fix PR #273).
set -Eeuo pipefail

BASE_SHA=28d99d3dad14d46a3ac42bc13cb7282fcb0e5dab
DATE=20261106
FORK_URL=https://github.com/wozt/Lichii-RX6600.git
UPSTREAM_URL=https://github.com/zortos293/Lichii.git
REPO="${RX6600_REPO:-$HOME/dev/Lichii-RX6600}"
PROFILE="${1:-stable}"
JOBS="${RX6600_JOBS:-8}"

usage() {
  cat <<'USAGE'
Usage: bash build_lichii_rx6600.sh [stable|balanced|lab]

  stable    Current official nx2 (#273 included) + scoped fixes (recommended first)
  balanced  stable + guarded performance work (recommended after stable passes)
  lab       balanced + experimental GPU-split and optional AA bypass

Environment:
  RX6600_REPO=~/dev/Lichii-RX6600   Separate clone; never modifies ~/dev/Lichii
  RX6600_JOBS=8                      Parallel build jobs
  RX6600_SKIP_TESTS=1                Build GUI only (tests recommended by default)

Run this script again for the next profile. It creates separate local git branches
rx6600/stable-20261106, rx6600/balanced-20261106 and rx6600/lab-20261106.
No push is performed automatically; no existing branch is reset.
USAGE
}

case "$PROFILE" in
  stable|balanced|lab) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "RX6600_JOBS must be a positive integer" >&2; exit 2; }

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

if [[ ! -d "$REPO/.git" ]]; then
  [[ ! -e "$REPO" ]] || fail "$REPO exists but is not a normal Git checkout. Set RX6600_REPO to a new path."
  printf 'Cloning fork into %s\n' "$REPO"
  git clone --branch nx2 "$FORK_URL" "$REPO"
fi

cd "$REPO"
origin_url=$(git remote get-url origin 2>/dev/null || true)
case "$origin_url" in
  https://github.com/wozt/Lichii-RX6600|https://github.com/wozt/Lichii-RX6600.git|git@github.com:wozt/Lichii-RX6600.git) ;;
  *) fail "origin is $origin_url (expected wozt/Lichii-RX6600); refusing to modify this repository" ;;
esac

# v1 attempted the obsolete PR #149 fix over code that already includes its guarded
# equivalent. Recover ONLY that exact cherry-pick, on the expected stable branch and
# with exactly the two expected unresolved files. Never abort unrelated user work.
if [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]]; then
  pending_sha=$(git rev-parse CHERRY_PICK_HEAD)
  pending_branch=$(git branch --show-current)
  if [[ "$pending_sha" == ceed7ca7f64f7eeb3f5524ae911ff131bfae2a0e &&
        "$pending_branch" == "rx6600/stable-$DATE" ]]; then
    mapfile -t conflicts < <(git diff --name-only --diff-filter=U)
    if [[ ${#conflicts[@]} -ne 2 ||
          "${conflicts[0]}" != src/video_core/fence_manager.h ||
          "${conflicts[1]}" != src/video_core/renderer_vulkan/vk_fence_manager.cpp ]]; then
      fail "Pending #149 cherry-pick has unexpected conflicts. Nothing was altered."
    fi
    printf '[recover] Abort the known duplicate #149 cherry-pick; preserve the newer guarded Vulkan fence implementation.\n'
    git cherry-pick --abort
  else
    fail "Unexpected cherry-pick $pending_sha on $pending_branch. Nothing was altered."
  fi
fi

[[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean. Commit/stash changes first; do not reset files."
if ! git remote get-url lichii-upstream >/dev/null 2>&1; then
  git remote add lichii-upstream "$UPSTREAM_URL"
else
  [[ "$(git remote get-url lichii-upstream)" == "$UPSTREAM_URL" ]] || fail "lichii-upstream points to a different URL"
fi

git fetch --no-tags origin nx2
git fetch --no-tags lichii-upstream nx2
if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  fail "Expected AMD baseline ${BASE_SHA} is unavailable"
fi
if ! git merge-base --is-ancestor "$BASE_SHA" origin/nx2; then
  fail "Fork nx2 does not include the verified PR #273 merge ($BASE_SHA); sync your fork first."
fi

branch_name() { printf 'rx6600/%s-%s' "$1" "$DATE"; }

switch_or_create() {
  local name="$1" base="$2"
  if git show-ref --verify --quiet "refs/heads/$name"; then
    git switch "$name"
  else
    git switch -c "$name" "$base"
  fi
  [[ -z "$(git status --porcelain)" ]] || fail "Uncommitted changes on $name"
}

# Every SHA is pinned to the PR state recorded on 2026-11-06.
# They are independent commits, not GitHub's moving branch heads.
# Only cherry-pick source commits; preserve authors and record source with -x.
apply_one() {
  local pr="$1" sha="$2" label="$3"
  if git merge-base --is-ancestor "$sha" HEAD 2>/dev/null ||
     grep -Fq "(cherry picked from commit $sha)" < <(git log HEAD --format=%B -n 150); then
    printf '[skip] PR #%s: %s (already in this branch)\n' "$pr" "$label"
    return 0
  fi
  printf '\n[apply] PR #%s: %s\n' "$pr" "$label"
  git fetch --no-tags lichii-upstream "pull/${pr}/head"
  git cat-file -e "${sha}^{commit}" || fail "Pinned commit $sha no longer available in PR #$pr"
  if ! git cherry-pick -x "$sha"; then
    printf '\n[conflict] PR #%s (%s); aborting this unsuccessful cherry-pick safely.\n' "$pr" "$sha" >&2
    if [[ -f "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]]; then
      git cherry-pick --abort || fail "Could not abort cherry-pick; keep the Git state for manual recovery"
    fi
    fail "PR #$pr needs a reviewed port against current nx2; no automatic conflict resolution."
  fi
}

# PR #149's initial deferred-submit fence fix is ALREADY present in our 28d99d3
# baseline, and is now guarded by GpuSplit::OnBackThread(). Cherry-picking its
# older unguarded implementation causes a conflict and would regress thread safety.
# The tests below check the required behaviour rather than trusting a comment.
verify_integrated_149() {
  local base=src/video_core/fence_manager.h
  local vk=src/video_core/renderer_vulkan/vk_fence_manager.cpp
  [[ -f "$base" && -f "$vk" ]] &&
    [[ $(grep -Fc 'SubmitDeferredWork();' "$base" || true) -ge 2 ]] &&
    grep -Fq 'virtual void SubmitDeferredWork() {}' "$base" &&
    grep -Fq 'void FenceManager::SubmitDeferredWork() {' "$vk" &&
    grep -Fq 'VideoCommon::GpuSplit::OnBackThread()' "$vk" &&
    grep -Fq 'scheduler.FlushDeferred();' "$vk"
}

stable_picks() {
  # Tested by contributors on AMD where stated; not a proven RX6600 package.
  if verify_integrated_149; then
    printf '[skip] PR #149: already integrated in nx2 with guarded Vulkan scheduler submission\n'
  else
    # Do not blindly reapply a conflicting old fence patch to a newer base.
    fail 'Cannot verify that PR #149 fix is integrated; review this base before proceeding.'
  fi
  apply_one 245 1735209618c4f7a5eda46b5b13d8ade9acfa9da5 'host-aligned bindless texture-handle reads (AMD alignment)'
  apply_one 241 d25d06b588fee6fed11a16617090d707987c4756 'recover native graphics shader lowering'
  apply_one 279 40d19de2d5df0cec2d33a79e3ce1066accc8a405 'IMAD uniform mirror register shadowing'
  apply_one 251 98ae0a44a130adc4fbf40cb288786b75c760c0e2 'Ocarina video clock/sync for low FPS'
  apply_one 278 dec8bfff6e2c89927d833198a8d3251d7f19d54c 'optional video/storage read throttle (default unchanged)'
}

balanced_picks() {
  apply_one 250 2e5d6d6ebd2719843c6b078c2e14557ec9f137c2 'skip provably empty cache invalidations'
  apply_one 264 d67ba50bfb276d580bf2de24762dae8892ecdd1c 'arm only previously unarmed read-trap pages'
  # Five original commits in PR #178, in dependency order.
  apply_one 178 95215fc248b5e844fb099babe1ebdf3a4b91ad4b 'GPU split: skip unneeded instance-loop writes (base)'
  apply_one 178 5a99c5473b2ced770f467069a0e3630a1dcacf2e 'GPU split: multi-method state'
  apply_one 178 72293610433e2e4a0d82e8b2d94a0e84b6ea909d 'GPU split: Replay shadow state'
  apply_one 178 e3153c836454ae96e57e89f4e263a888dd6fcfee 'GPU split: retain index buffer dirty marking'
  apply_one 178 994b99c35b86979fbe513edaf17f0a29e905d0f7 'GPU split: multi-word instance-loop changes'
}

lab_picks() {
  # Complex split-thread changes; test only after stable/balanced and keep a fallback.
  apply_one 243 1117fa6949896d29ca373273c603f1968b68bccb 'early macro DMA reads (base)'
  apply_one 243 bc39d5262c02af8f8836003ba613db8461148b5c 'only report pages / contiguous mapping'
  apply_one 243 c303d1085d9433a9e675a5159c6b8c37af1b0c97 'validate each page of an early DMA read'
  apply_one 215 0bdc4ad004d9d626ea8281048848d1470130e50c 'flush query cache before macro DMA reads'
  apply_one 215 9ab3d845b82a169dd86e8697c95fe3a1b3d2c212 'wait for pending query reports (may conflict with #243)'
  apply_one 282 03c3aa3d60104de19107b0378d7f064e21bf6952 'optional Ocarina AA/sharpening bypass (off by default)'
}

stable_branch=$(branch_name stable)
switch_or_create "$stable_branch" origin/nx2
stable_picks

if [[ "$PROFILE" == balanced || "$PROFILE" == lab ]]; then
  balanced_branch=$(branch_name balanced)
  switch_or_create "$balanced_branch" "$stable_branch"
  balanced_picks
fi

if [[ "$PROFILE" == lab ]]; then
  lab_branch=$(branch_name lab)
  switch_or_create "$lab_branch" "$balanced_branch"
  lab_picks
fi

[[ -z "$(git status --porcelain)" ]] || fail 'Working tree is not clean after cherry-picks'

build_dir="build/rx6600-${PROFILE}"
printf '\nConfiguring %s at %s (jobs=%s)\n' "$PROFILE" "$(git rev-parse --short HEAD)" "$JOBS"
test_setting=ON
[[ "${RX6600_SKIP_TESTS:-0}" == 1 ]] && test_setting=OFF
cmake -S . -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DYUZU_TESTS="$test_setting" \
  -DBUILD_TESTING="$test_setting" \
  -DENABLE_WERROR=OFF \
  -DENABLE_QT=ON \
  -DYUZU_USE_BUNDLED_QT=OFF \
  -DYUZU_USE_BUNDLED_SDL3=ON \
  -DVulkanHeaders_FORCE_BUNDLED=ON \
  -DVulkanUtilityLibraries_FORCE_BUNDLED=ON \
  -DENABLE_UPDATE_CHECKER=OFF

if [[ "$test_setting" == ON ]]; then
  cmake --build "$build_dir" --target yuzu tests --parallel "$JOBS"
  ctest --test-dir "$build_dir" --output-on-failure --no-tests=error
else
  cmake --build "$build_dir" --target yuzu --parallel "$JOBS"
fi

binary="$REPO/$build_dir/bin/lichii"
[[ -x "$binary" ]] || fail "Build reported success but binary was not found at $binary"

cat <<EOF3

BUILD OK: $PROFILE ($(git rev-parse --short HEAD))
Executable: $binary
Git branch: $(git branch --show-current)

Run (isolated shader/cache directory; existing saves/config are still shared):
  XDG_CACHE_HOME=\"\$HOME/.cache/lichii-rx6600-$PROFILE\" \"$binary\"

After gameplay verification, publish this exact tested branch:
  cd \"$REPO\"
  git push -u origin $(git branch --show-current)

Important: this is a non-PGO build; do not compare raw FPS directly to PGO
releases until the same code is tested under comparable build settings.
EOF3
