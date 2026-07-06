# morphllm — Morph plugin for omp-sbx

This directory contains the files needed to install and patch the
[`pi-morphllm-plugin`](https://www.npmjs.com/package/pi-morphllm-plugin) npm
package inside the omp-sbx Docker image.

The plugin is **opt-in** and disabled by default. Enable it at build time:

```sh
docker build --build-arg INSTALL_MORPH_PLUGIN=1 -t omp-sbx:latest -f sbx-kit/Dockerfile .
```

---

## What the plugin adds

Once installed, Morph extends omp with three extra tools:

| Tool | Description |
|---|---|
| `morph_fastapply` | Applies code edits via the Morph API (faster, cheaper than the native diff approach) |
| `warpgrep_codebase_search` | Semantic codebase search powered by WarpGrep |
| `warpgrep_github_search` | GitHub code search via Morph's remote repo index, with a shallow-clone fallback when that backend is unavailable |

It also enables **auto-compaction**: when the context window fills past the
configured threshold, omp compacts the conversation using the Morph API.

---

## Configuration — morph.json.template

`morph.json.template` is copied to `/opt/morph-config/morph.json` during the
Docker build. The startup kit script (`sbx-kit/spec.yaml`) symlinks it into
`~/.pi/plugins/morph.json` at container launch.

Key fields:

| Field | Default | Description |
|---|---|---|
| `apiKey` | `"multiple"` | Set to your Morph API key, or `"multiple"` to read from `apiKeyFile` |
| `apiKeyFile` | `~/.pi/agent/morph.env` | Newline-separated list of API keys for round-robin rotation |
| `baseUrl` | `https://api.morphllm.com` | Morph API endpoint |
| `codeSearchUrl` | `https://repos.morphllm.com` | Preferred WarpGrep GitHub search endpoint before fallback |
| `editEnabled` | `true` | Enable `morph_fastapply` |
| `warpgrepEnabled` | `true` | Enable `warpgrep_codebase_search` |
| `warpgrepGithubEnabled` | `true` | Enable `warpgrep_github_search` |
| `autoCompactEnabled` | `false` | Enable automatic context compaction |
| `routing.fallbackToNativeTools` | `true` | Fall back to omp's native tools if Morph fails |

---

## Compatibility patches (why they are needed)

`omp` embeds `pi`'s modules with an internal loader that breaks the plugin in
three ways. `morph-install.sh` applies fixes at build time:

### 1. `withFileMutationQueue` shim (`morph-withfilemutationqueue.shim.js`)

omp's bundled `@mariozechner/pi-coding-agent` no longer exports
`withFileMutationQueue`. The plugin imports it by name at startup, causing an
immediate crash. The shim re-implements the function as a per-path async mutex
and is injected into the plugin's `extensions/morph/` directory.

### 2. Morph SDK bundle

omp's internal loader cannot resolve `@morphllm/morphsdk`'s transitive bare
specifier dependencies (`ai`, `@vscode/ripgrep`, etc.) from the plugin's own
`node_modules`. `morph-install.sh` pre-bundles the entire SDK into a single
self-contained ESM file using `bun build` and rewrites the plugin's dynamic
import to point at the bundle.

### 3. GitHub-search routing + fallback (`morph-patch.py`)

The public WarpGrep GitHub frontend (`morphllm.com` Vercel) is unreliable from
the sbx egress path. `morph-patch.py` patches `config.js` and `index.js` in the
installed plugin to:

- Parse `codeSearchUrl` from `morph.json` in the config loader.
- Pass it through to the WarpGrep client constructor so GitHub searches prefer
  `https://repos.morphllm.com`.
- Fall back to a shallow public `git clone` plus local WarpGrep execution when
  Morph's remote repo-import backend fails.

---

## Files

| File | Purpose |
|---|---|
| `morph-install.sh` | Main install script — run by the Dockerfile as the `agent` user |
| `morph-patch.py` | Python script that patches `config.js` and `index.js` in the installed plugin |
| `morph-withfilemutationqueue.shim.js` | Drop-in shim for the removed `withFileMutationQueue` export |
| `morph.json.template` | Morph plugin configuration template |
