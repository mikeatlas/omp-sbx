#!/usr/bin/env bash
# morph-install.sh — installs + patches pi-morphllm-plugin for use under omp.
#
# Runs as the `agent` user inside the Docker build. Expects:
#   /opt/morph-config/withFileMutationQueue.shim.js  (COPY'd by Dockerfile)
#   /opt/morph-config/morph-patch.py                 (COPY'd by Dockerfile)
#
# omp's bun runtime uses a strict ESM resolver that does not walk parent
# node_modules for type:module packages. Every package with deps needs those
# deps present in its own node_modules/. Three classes of fix:
#   1. @vscode/ripgrep stub — SDK imports it at load time but never calls it
#      at runtime (omp-sbx uses system rg via spawnSync instead).
#   2. isomorphic-git dep scope — isomorphic-git is a static import in the SDK
#      git client; its deps (crc-32 etc.) live at sibling level which bun can't
#      walk to from a type:module package; symlink them inside isomorphic-git/.
#   3. withFileMutationQueue shim — @earendil-works/pi-coding-agent not installed.
#   4. streamSteps:true patch — streamSteps:false returns a bare Promise, not a
#      generator; the plugin's for(;;){await generator.next()} loop then breaks.
# No bundling: bun collapses async generators to Promises, breaking WarpGrep.
set -euo pipefail

npm uninstall -g pi-morphllm-plugin 2>/dev/null || true
npm install -g pi-morphllm-plugin

MORPH_TOOLS="$(npm root -g)/pi-morphllm-plugin/dist/extensions/morph/tools"
MORPH_SDK="$(npm root -g)/pi-morphllm-plugin/node_modules/@morphllm/morphsdk"
MORPH_INDEX="$(npm root -g)/pi-morphllm-plugin/dist/extensions/morph/index.js"
MORPH_CONFIG="$(npm root -g)/pi-morphllm-plugin/dist/extensions/morph/config.js"

# 1. Stub @vscode/ripgrep in two locations so bun's ESM resolver finds it
#    regardless of which chunk file triggers the import at runtime.
for STUB_DIR in "$MORPH_SDK/node_modules/@vscode/ripgrep" "$MORPH_SDK/dist/node_modules/@vscode/ripgrep"; do
  mkdir -p "$STUB_DIR"
  printf '{"name":"@vscode/ripgrep","version":"1.0.0","type":"module","main":"index.js","exports":{".":"./index.js"}}\n' \
    > "$STUB_DIR/package.json"
  printf '// Stub: omp-sbx uses system rg via spawnSync\nexport const rgPath = "rg";\nexport default { rgPath: "rg" };\n' \
    > "$STUB_DIR/index.js"
done

# 2. Scope isomorphic-git's deps inside its own node_modules so bun's strict
#    ESM resolver finds them. The deps are installed at plugin node_modules level
#    but bun won't walk up from a type:module package to find siblings.
ISOGIT_DEPS="async-lock clean-git-ref crc-32 diff3 ignore minimisted pako pify readable-stream sha.js simple-get"
PLUGIN_NM="$(npm root -g)/pi-morphllm-plugin/node_modules"
ISOGIT_NM="$PLUGIN_NM/isomorphic-git/node_modules"
mkdir -p "$ISOGIT_NM"
for dep in $ISOGIT_DEPS; do
  [ -d "$PLUGIN_NM/$dep" ] && [ ! -e "$ISOGIT_NM/$dep" ] && \
    ln -sf "$PLUGIN_NM/$dep" "$ISOGIT_NM/$dep" || true
done

# 3. Shim the removed withFileMutationQueue import in the compiled fastapply tool.
cp /opt/morph-config/withFileMutationQueue.shim.js "$MORPH_TOOLS/withFileMutationQueue.shim.js"
sed -i \
  's|import { withFileMutationQueue } from "@earendil-works/pi-coding-agent";|import { withFileMutationQueue } from "./withFileMutationQueue.shim.js";|' \
  "$MORPH_TOOLS/fastapply.js"

# 4. Patch warpgrep.js: use streamSteps:true so client.execute() returns an
#    async generator. streamSteps:false returns a bare Promise; the plugin's
#    for(;;) { await generator.next() } loop then fails with "next is not a function".
sed -i 's/streamSteps: false/streamSteps: true/g' "$MORPH_TOOLS/warpgrep.js"

# 5. Apply remaining plugin patches (footer status suppression).
python3 /opt/morph-config/morph-patch.py "$MORPH_CONFIG" "$MORPH_INDEX"
