// Compatibility shim for pi-morphllm-plugin on omp >= 16.x.
//
// omp 16.x removed the `withFileMutationQueue` export from the bundled
// @mariozechner/pi-coding-agent module (replaced by a file-mutation
// versioning model: bumpFileMutationVersion / getFileMutationVersion).
// pi-morphllm-plugin@0.1.9 (latest) still imports it, so the plugin fails
// to load and no morph tools register.
//
// The plugin only uses withFileMutationQueue(absolutePath, fn) to serialize
// mutations per file path (extensions/morph/index.js). A local per-path async
// mutex is a behaviour-preserving drop-in.
const _fileMutationQueues = new Map();

export async function withFileMutationQueue(filePath, fn) {
	const prev = _fileMutationQueues.get(filePath) ?? Promise.resolve();
	const next = prev.then(() => fn());
	// Swallow rejection in the stored tail so later callers still run, while
	// letting the original caller observe fn's rejection via `next`.
	const tail = next.then(() => {}, () => {});
	_fileMutationQueues.set(filePath, tail);
	tail.then(() => {
		if (_fileMutationQueues.get(filePath) === tail) {
			_fileMutationQueues.delete(filePath);
		}
	});
	return await next;
}
