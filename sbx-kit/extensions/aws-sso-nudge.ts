/**
 * Keeps the sandbox's AWS SSO login alive without ending a turn on an auth
 * error.
 *
 * omp-init.sh passes this with --extension only when a project opts into
 * Bedrock. Two lifetimes matter, and only the second one needs a human:
 *
 *   - The access token lasts about an hour. The AWS CLI renews it from the
 *     cached refresh token, silently and with no browser.
 *   - The client registration behind that refresh token lasts about a month.
 *     Once it lapses, renewal stops working and someone has to visit a URL.
 *
 * So this watches the registration and warns in the chat while there is still
 * room to act, pointing at /aws-login. When credentials actually stop working it
 * runs the device-code login itself, prints the URL, and waits for the approval.
 */
import { spawn } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CACHE_DIR = join(homedir(), ".aws", "sso", "cache");
const STATUS_KEY = "aws-sso";
const CHECK_INTERVAL_MS = 15 * 60_000;
const DEFAULT_WARN_DAYS = 2;
const LOGIN_TIMEOUT_MS = 5 * 60_000;

interface Ui {
	notify(message: string, type?: "info" | "warning" | "error"): void;
	setStatus(key: string, text: string | undefined): void;
}
interface Ctx {
	ui: Ui;
}
interface ExecResult {
	code: number;
}
interface Pi {
	on(event: string, handler: (event: { status?: number }, ctx: Ctx) => void): void;
	registerCommand(
		name: string,
		options: { description?: string; handler: (args: string, ctx: Ctx) => Promise<void> },
	): void;
	exec(command: string, args: string[], options?: { timeout?: number }): Promise<ExecResult>;
}

/** Days of remaining registration at which the warning starts. */
function warnDays(): number {
	const configured = Number(process.env.OMP_SBX_AWS_SSO_WARN_DAYS);
	return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_WARN_DAYS;
}

/**
 * The live SSO session's registration expiry, or null when none is readable.
 *
 * The cache directory accumulates entries: superseded sessions, plus client
 * registrations that carry no refreshToken. Only a refreshToken entry describes
 * a session, and the one with the furthest access-token expiry is the live one.
 * A stale session can hold a later registrationExpiresAt than the live one, so
 * picking by that field alone reports an expiry that no longer applies.
 */
function registrationExpiry(): number | null {
	let entries: string[];
	try {
		entries = readdirSync(CACHE_DIR);
	} catch {
		return null;
	}

	let live: { expiresAt: number; registrationExpiresAt: number } | null = null;
	for (const entry of entries) {
		if (!entry.endsWith(".json")) continue;
		try {
			const token = JSON.parse(readFileSync(join(CACHE_DIR, entry), "utf8"));
			if (!token.refreshToken || !token.expiresAt || !token.registrationExpiresAt) continue;
			const expiresAt = Date.parse(token.expiresAt);
			const registrationExpiresAt = Date.parse(token.registrationExpiresAt);
			if (!Number.isFinite(expiresAt) || !Number.isFinite(registrationExpiresAt)) continue;
			if (live === null || expiresAt > live.expiresAt) {
				live = { expiresAt, registrationExpiresAt };
			}
		} catch {
			// A half-written or malformed cache entry is not worth reporting.
		}
	}
	return live?.registrationExpiresAt ?? null;
}

export default function (pi: Pi): void {
	const profile = process.env.OMP_SBX_AWS_PROFILE ?? "";
	// Without a profile there is nothing to watch. omp-init.sh only loads this
	// extension for a project that opted in, so this is a second line of defense.
	if (!profile) return;

	let timer: ReturnType<typeof setInterval> | undefined;
	let loggingIn = false;
	let warned = false;

	/**
	 * Whether the AWS CLI can produce credentials right now.
	 *
	 * This covers what the expiry check cannot see: a revoked role, a session
	 * ended from the AWS console, or a refresh that fails for its own reasons.
	 */
	async function credentialsWork(): Promise<boolean> {
		try {
			const result = await pi.exec(
				"aws",
				["configure", "export-credentials", "--profile", process.env.AWS_PROFILE ?? profile],
				{ timeout: 30_000 },
			);
			return result.code === 0;
		} catch {
			return false;
		}
	}

	/**
	 * Runs the device-code login, reporting the URL through the chat.
	 *
	 * No browser runs in the sandbox, so the CLI's own "opening your browser"
	 * path is useless here. --no-browser prints a URL to open on the host and
	 * then blocks, polling, until the approval lands - which is exactly the wait
	 * this needs. pi.exec buffers until exit, so it cannot show a URL that only
	 * matters while the process is still running.
	 */
	function runLogin(ctx: Ctx): Promise<boolean> {
		return new Promise((resolve) => {
			const proc = spawn("aws", ["sso", "login", "--no-browser", "--profile", profile], {
				stdio: ["ignore", "pipe", "pipe"],
			});

			let announced = false;
			const scan = (chunk: Buffer) => {
				if (announced) return;
				const text = chunk.toString();
				const url = /https:\/\/\S+/.exec(text)?.[0];
				if (!url) return;
				announced = true;
				const code = /\b[A-Z]{4}-[A-Z]{4}\b/.exec(text)?.[0];
				ctx.ui.notify(
					`AWS SSO login: open this on your host${code ? ` and confirm code ${code}` : ""}\n${url}`,
					"warning",
				);
			};
			proc.stdout?.on("data", scan);
			proc.stderr?.on("data", scan);

			// The CLI polls until the device code expires, which outlasts any
			// useful wait inside a session.
			const timeout = setTimeout(() => proc.kill(), LOGIN_TIMEOUT_MS);
			proc.on("error", () => {
				clearTimeout(timeout);
				resolve(false);
			});
			proc.on("close", (code: number | null) => {
				clearTimeout(timeout);
				resolve(code === 0);
			});
		});
	}

	/** Runs one login at a time, and reports the outcome either way. */
	async function relogin(ctx: Ctx, reason: string): Promise<void> {
		if (loggingIn) return;
		loggingIn = true;
		ctx.ui.setStatus(STATUS_KEY, "aws sso: waiting for approval");
		try {
			ctx.ui.notify(reason, "warning");
			if (await runLogin(ctx)) {
				ctx.ui.notify("AWS SSO login complete - Bedrock is available again.", "info");
				warned = false;
			} else {
				ctx.ui.notify(
					`AWS SSO login did not complete. Retry with /aws-login, or run: aws sso login --no-browser --profile ${profile}`,
					"error",
				);
			}
		} finally {
			loggingIn = false;
		}
	}

	async function check(ctx: Ctx): Promise<void> {
		if (loggingIn) return;

		if (!(await credentialsWork())) {
			ctx.ui.setStatus(STATUS_KEY, "aws sso: signed out");
			await relogin(ctx, "AWS SSO credentials are unavailable.");
			return;
		}

		const expiresAt = registrationExpiry();
		if (expiresAt === null) {
			// Credentials work, so say nothing about a cache this cannot read.
			ctx.ui.setStatus(STATUS_KEY, "aws sso: ok");
			return;
		}

		const daysLeft = Math.floor((expiresAt - Date.now()) / 86_400_000);
		ctx.ui.setStatus(STATUS_KEY, `aws sso: ${daysLeft}d`);

		if (daysLeft <= warnDays()) {
			if (!warned) {
				warned = true;
				ctx.ui.notify(
					`AWS SSO login expires in ${daysLeft}d. Run /aws-login to renew it before it interrupts a turn.`,
					"warning",
				);
			}
		} else {
			// A renewed login re-arms the warning.
			warned = false;
		}
	}

	pi.registerCommand("aws-login", {
		description: "Renew the AWS SSO login for Bedrock (prints a URL to open on the host)",
		handler: async (_args, ctx) => {
			await relogin(ctx, `Starting AWS SSO login for ${profile}.`);
		},
	});

	pi.on("session_start", (_event, ctx) => {
		void check(ctx);
		timer = setInterval(() => void check(ctx), CHECK_INTERVAL_MS);
	});

	// Shutdown handlers get about two seconds, so this stays synchronous.
	pi.on("session_shutdown", () => {
		if (timer) clearInterval(timer);
	});

	// Credentials can lapse mid-turn, between two scheduled checks.
	pi.on("after_provider_response", (event, ctx) => {
		if (event.status === 401 || event.status === 403) {
			void relogin(ctx, `Bedrock rejected the credentials (${event.status}).`);
		}
	});
}
