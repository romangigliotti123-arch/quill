import { createHash } from 'node:crypto';
import { chmodSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { dataFile } from '../paths';
import { trim } from '../text/strings';

// NVIDIA NIM, OpenAI-compatible. The AI layer and nothing else — transcription
// is on-device and stays that way, so every path through this file has a "then
// we use the deterministic result instead" ending. A network that is down,
// slow, rate-limited or lying must cost a dictation nothing but the deadline it
// was already budgeted.

// MARK: - Credential

/// Where the key comes from, and the only place it is ever read.
///
/// Environment first so a rig or a test can override without touching the
/// user's file; file second so the shipped app needs no environment at all. The
/// key is never a literal in this repo — it is git-tracked, and a key in a
/// commit is not something you fix by deleting the line.
export const NIM_KEY_ENVIRONMENT_VARIABLE = 'QUILL_NIM_API_KEY';

export function nimKeyFile(): string {
  return dataFile('nim-key.txt');
}

export function loadNIMKey(
  environment: NodeJS.ProcessEnv = process.env,
  fileURL: string = nimKeyFile(),
): string | null {
  const fromEnvironment = environment[NIM_KEY_ENVIRONMENT_VARIABLE];
  if (fromEnvironment && trim(fromEnvironment).length > 0) return trim(fromEnvironment);
  try {
    const text = trim(readFileSync(fileURL, 'utf8'));
    return text.length === 0 ? null : text;
  } catch {
    return null;
  }
}

/// Write the key where `loadNIMKey` will find it.
///
/// 0600, and an empty string removes it, which is how "I pasted the wrong one"
/// is undone.
///
/// On Windows `chmod` is a no-op — NTFS permissions are ACLs and Node cannot
/// set them. The file therefore inherits the ACL of `%APPDATA%\Quill`, which is
/// already user-only on a default install. Said plainly rather than pretended
/// about: on a machine where that folder has been widened, so is this file.
export function saveNIMKey(key: string, fileURL: string = nimKeyFile()): boolean {
  const trimmed = trim(key);
  try {
    if (trimmed.length === 0) {
      rmSync(fileURL, { force: true });
      return true;
    }
    mkdirSync(dirname(fileURL), { recursive: true });
    writeFileSync(fileURL, trimmed, { encoding: 'utf8', mode: 0o600 });
    if (process.platform !== 'win32') chmodSync(fileURL, 0o600);
    return true;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('[quill] could not write the API key', error);
    return false;
  }
}

/// Something a human can quote in a bug report that is not the key. Eight hex
/// characters of SHA-256 identifies which key is loaded and reverses to
/// nothing. A prefix of the key itself would be simpler and is not offered on
/// purpose — "just the first six characters" is how keys end up in logs.
export function nimKeyFingerprint(key: string): string {
  return `${createHash('sha256').update(key, 'utf8').digest('hex').slice(0, 8)}…`;
}

// MARK: - Errors

export type NIMErrorKind =
  | { kind: 'notConfigured' }
  | { kind: 'offline'; why: string }
  | { kind: 'unauthorized' }
  | { kind: 'modelUnavailable'; model: string; detail: string }
  | { kind: 'rateLimited'; retryAfter: number | null }
  | { kind: 'serviceUnavailable'; status: number; detail: string }
  | { kind: 'malformedResponse'; what: string }
  | { kind: 'emptyCompletion'; model: string }
  | { kind: 'deadlineExceeded'; milliseconds: number }
  | { kind: 'cancelled' };

export class NIMError extends Error {
  readonly detail: NIMErrorKind;

  constructor(detail: NIMErrorKind) {
    super(describeNIMError(detail));
    this.name = 'NIMError';
    this.detail = detail;
  }

  /// Worth trying again with the same request, if there is budget for it.
  get isTransient(): boolean {
    return this.detail.kind === 'rateLimited' || this.detail.kind === 'serviceUnavailable';
  }

  /// Counts toward tripping the circuit breaker. Only failures that a retry in
  /// a minute might genuinely fix — a bad key will still be bad, and
  /// short-circuiting on it would hide the one error the user must act on.
  ///
  /// `deadlineExceeded` is deliberately NOT here, and the live harness is why:
  /// with it included, two dictations at a tight deadline tripped the breaker
  /// and switched the AI off for the following minute. A deadline miss means
  /// the service answered too slowly for this caller, not that it is
  /// unreachable, and it costs exactly the deadline the caller had budgeted.
  get trippsBreaker(): boolean {
    return this.detail.kind === 'offline'
      || this.detail.kind === 'rateLimited'
      || this.detail.kind === 'serviceUnavailable';
  }
}

export function describeNIMError(detail: NIMErrorKind): string {
  switch (detail.kind) {
    case 'notConfigured':
      return 'AI features are off because no key is configured. Put an NVIDIA NIM key in '
        + `${nimKeyFile()}, or set ${NIM_KEY_ENVIRONMENT_VARIABLE}, then reopen Quill.`;
    case 'offline':
      return `Could not reach NVIDIA — ${detail.why}. Dictation still works; the AI cleanup is skipped.`;
    case 'unauthorized':
      return 'NVIDIA rejected the API key. It is present but not valid — check it has not been '
        + 'rotated or revoked at build.nvidia.com.';
    case 'modelUnavailable':
      return `The model "${detail.model}" is not available to this NVIDIA account. ${detail.detail}`;
    case 'rateLimited': {
      const when = detail.retryAfter === null ? '' : ` Retry in about ${Math.round(detail.retryAfter)}s.`;
      return `NVIDIA is rate-limiting this key.${when}`;
    }
    case 'serviceUnavailable':
      return `NVIDIA returned ${detail.status}. ${detail.detail}`;
    case 'malformedResponse':
      return `NVIDIA returned something this client could not read: ${detail.what}`;
    case 'emptyCompletion':
      return `"${detail.model}" returned an empty completion. Reasoning models do this — their text `
        + 'goes to reasoning_content, not content. Pick a non-reasoning instruct model.';
    case 'deadlineExceeded':
      return `AI cleanup did not finish within ${detail.milliseconds}ms; the deterministic cleanup was used instead.`;
    case 'cancelled':
      return 'AI cleanup was cancelled.';
  }
}

// MARK: - Reachability

/// The answer to "why is the AI not doing anything", in a form the settings
/// pane can render. Every one of these will be hit, so they are separate cases
/// rather than one error string.
export type NIMStatus =
  | { kind: 'ready'; model: string; latencyMs: number }
  | { kind: 'notConfigured' }
  | { kind: 'offline'; why: string }
  | { kind: 'badKey' }
  | { kind: 'modelUnavailable'; model: string; detail: string }
  | { kind: 'serviceBusy'; detail: string };

export function nimStatusIsUsable(status: NIMStatus): boolean {
  return status.kind === 'ready';
}

export function nimStatusHeadline(status: NIMStatus): string {
  switch (status.kind) {
    case 'ready': return `AI ready — ${status.model}, ${status.latencyMs}ms`;
    case 'notConfigured': return 'AI features are off because no key is configured';
    case 'offline': return 'AI unavailable — no network';
    case 'badKey': return 'AI unavailable — the API key is not valid';
    case 'modelUnavailable': return `AI unavailable — "${status.model}" is not served to this account`;
    case 'serviceBusy': return 'AI unavailable — NVIDIA is busy or rate-limiting';
  }
}

export function nimStatusDetail(status: NIMStatus): string {
  switch (status.kind) {
    case 'ready':
      return 'Transcription is on-device either way; this only affects the cleanup pass.';
    case 'notConfigured':
      return describeNIMError({ kind: 'notConfigured' });
    case 'offline':
      return `${status.why}. Dictation is unaffected — it never needed the network.`;
    case 'badKey':
      return describeNIMError({ kind: 'unauthorized' });
    case 'modelUnavailable':
      return `${status.detail} Pick another model; /v1/models lists the catalogue, `
        + 'but a listed model can still 404 for an account.';
    case 'serviceBusy':
      return status.detail;
  }
}

// MARK: - Config

/// Which model Quill talks to, how it is asked, and how long it is allowed to
/// take.
///
/// Everything here was measured, not chosen.
///
/// # Benchmark — one keep-alive HTTPS connection per model, 4 real transcripts
///
///     model                              p50      p90     verdict
///     ─────────────────────────────────────────────────────────────────────
///     meta/llama-3.1-8b-instruct        328ms    512ms    best latency, clean output
///     nvidia/nemotron-mini-4b-instruct  600ms    719ms    wraps output in quotes
///     mistralai/mistral-nemotron        614ms    751ms    HALLUCINATED: "neglify" → "Nebula"
///     google/gemma-4-31b-it            1184ms   2920ms    best accuracy, 3.6× the latency
///     openai/gpt-oss-20b               1250ms   2866ms    UNUSABLE: content is null
///     deepseek-ai/deepseek-v4-flash    5073ms   6796ms    good output, far too slow
///
/// ## The 250ms question
///
/// No. Not this model, and not any model on this endpoint. The floor is the
/// network, not the GPU. A bare `GET /v1/models` round-trips in 146–197ms and a
/// completion capped at ONE token costs 195–223ms. Share of real calls
/// finishing inside a given deadline (n=37, warm connection):
///
///     250ms → 11%      350ms → 78%      450ms → 97%
///     300ms → 46%      400ms → 89%      500ms → 97%
///
/// 450ms is the smallest deadline at which the pass is worth having.
export interface AIConfig {
  baseURL: string;
  model: string;
  systemPrompt: string;
  maxTokens: number;
  temperature: number;
  topP: number;
  /// Per-attempt ceiling. Distinct from the caller's deadline: the deadline is
  /// a promise to the user, this is a promise to the socket. Whichever is
  /// shorter wins.
  requestTimeoutMs: number;
  /// Total attempts including the first. Retries are still bounded by the
  /// caller's deadline, so on the dictation path this is usually academic.
  maxAttempts: number;
  initialBackoffMs: number;
  /// After this many consecutive network failures the client stops trying until
  /// `breakerCooldownMs` has passed. People dictate on trains; without this,
  /// every single dictation in a tunnel pays the full deadline in dead waiting
  /// before falling back to text it could have had immediately.
  breakerThreshold: number;
  breakerCooldownMs: number;
}

export const DEFAULT_NIM_BASE_URL = 'https://integrate.api.nvidia.com/v1';

/// What the deadline should be if the model pass is ever to fire. 450ms.
export const RECOMMENDED_CLEANUP_DEADLINE_MS = 450;

export function defaultAIConfig(systemPrompt: string): AIConfig {
  return {
    baseURL: DEFAULT_NIM_BASE_URL,
    // On the real pipeline it produced character-identical output to the
    // largest model tested, 5.5× faster at p50 and 11× faster at p90.
    model: 'meta/llama-3.1-8b-instruct',
    systemPrompt,
    // A cleanup is never longer than what went in. Capping low also caps the
    // damage a model does when it decides to answer the dictation instead of
    // tidying it, and caps the time it can spend doing so.
    maxTokens: 160,
    temperature: 0,
    topP: 1,
    requestTimeoutMs: 8_000,
    maxAttempts: 3,
    initialBackoffMs: 250,
    breakerThreshold: 2,
    breakerCooldownMs: 60_000,
  };
}

// MARK: - The seam

/// The one thing the cleaner needs from a language-model client.
///
/// An interface rather than a direct dependency on the client because the
/// interesting tests are the miserable ones — the model hangs, the model
/// returns an essay, the model quietly rewrites a sentence to the same length —
/// and none of those can be provoked against a real endpoint on demand.
export interface AICompleting {
  readonly isConfigured: boolean;
  /// False when the client has already decided the network is gone. Checking
  /// costs nothing and saves the whole deadline on every dictation in a tunnel.
  readonly isReadyToTry: boolean;
  complete(system: string, user: string, model: string | null, deadlineMs: number): Promise<string>;
}

// MARK: - Client

export class NIMClient implements AICompleting {
  readonly config: AIConfig;
  private readonly key: string | null;
  private readonly vocabulary: string[];

  private consecutiveFailures = 0;
  private openedAt: number | null = null;

  constructor(options: {
    config?: AIConfig;
    key?: string | null;
    vocabulary?: string[];
    systemPrompt?: string;
  } = {}) {
    this.config = options.config ?? defaultAIConfig(options.systemPrompt ?? '');
    this.key = options.key === undefined ? loadNIMKey() : options.key;
    this.vocabulary = options.vocabulary ?? [];
  }

  get isConfigured(): boolean { return this.key !== null; }
  get isReadyToTry(): boolean { return !this.isBreakerOpen; }

  /// Safe to log. Never the key.
  get keyFingerprint(): string {
    return this.key ? nimKeyFingerprint(this.key) : 'none';
  }

  private get chatCompletionsURL(): string { return `${this.config.baseURL}/chat/completions`; }
  private get modelsURL(): string { return `${this.config.baseURL}/models`; }

  /// The version that tells you why. For settings, diagnostics and the rig —
  /// not for the dictation path, which must never surface an AI error to
  /// someone who just wanted their words typed.
  async complete(
    system: string,
    user: string,
    model: string | null,
    deadlineMs: number,
  ): Promise<string> {
    if (!this.key) throw new NIMError({ kind: 'notConfigured' });
    const chosen = model ?? this.config.model;
    const started = Date.now();

    let attempt = 0;
    let backoff = this.config.initialBackoffMs;
    let lastError = new NIMError({ kind: 'deadlineExceeded', milliseconds: deadlineMs });

    while (attempt < this.config.maxAttempts) {
      attempt += 1;
      const remaining = deadlineMs - (Date.now() - started);
      if (remaining <= 20) break;

      try {
        const text = await this.performChat(
          system, user, chosen, this.key, Math.min(remaining, this.config.requestTimeoutMs),
        );
        this.noteSuccess();
        return text;
      } catch (error) {
        const nimError = error instanceof NIMError
          ? error
          : new NIMError({ kind: 'offline', why: String(error) });
        lastError = nimError;
        if (nimError.trippsBreaker) this.noteFailure();
        if (!nimError.isTransient) throw nimError;

        // Only sleep if the budget can still cover the backoff *and* a request
        // afterwards. On a 250ms dictation deadline it never can, which is the
        // correct behaviour: fail out and let the fast pass ship rather than
        // burn the user's budget on politeness.
        const left = deadlineMs - (Date.now() - started);
        const hint = nimError.detail.kind === 'rateLimited' && nimError.detail.retryAfter !== null
          ? nimError.detail.retryAfter * 1000
          : backoff;
        const wait = Math.min(backoff, hint);
        if (left <= wait + 120) break;
        await sleep(wait);
        backoff *= 2;
      }
    }
    throw lastError;
  }

  /// Distinguishes "no network" from "bad key" from "model unavailable" by
  /// actually doing the three things that tell them apart, in the order that
  /// costs least. A GET of the catalogue answers network and credential; only a
  /// real completion answers whether the model is served to this account,
  /// because the catalogue happily lists models that 404 on use.
  async status(deadlineMs = 12_000): Promise<NIMStatus> {
    if (!this.key) return { kind: 'notConfigured' };
    const started = Date.now();

    try {
      const response = await fetchWithDeadline(this.modelsURL, {
        method: 'GET',
        headers: { Authorization: `Bearer ${this.key}`, Accept: 'application/json' },
      }, deadlineMs);
      const body = await response.text();
      switch (response.status) {
        case 200: break;
        case 401:
        case 403: return { kind: 'badKey' };
        case 429: return {
          kind: 'serviceBusy',
          detail: describeNIMError({ kind: 'rateLimited', retryAfter: retryAfterSeconds(response) }),
        };
        default: return {
          kind: 'serviceBusy',
          detail: `Catalogue lookup returned ${response.status}. ${errorDetail(body, this.key)}`,
        };
      }
    } catch (error) {
      if (error instanceof NIMError) {
        switch (error.detail.kind) {
          case 'offline': return { kind: 'offline', why: error.detail.why };
          case 'unauthorized': return { kind: 'badKey' };
          case 'deadlineExceeded':
            return { kind: 'offline', why: `the catalogue did not answer in ${deadlineMs}ms` };
          default: return { kind: 'serviceBusy', detail: error.message };
        }
      }
      return { kind: 'offline', why: String(error) };
    }

    // Credential and network are proven. Now prove the model.
    const left = deadlineMs - (Date.now() - started);
    try {
      await this.complete('Reply with the single word OK.', 'ping', null, Math.max(left, 2_000));
      return { kind: 'ready', model: this.config.model, latencyMs: Date.now() - started };
    } catch (error) {
      if (error instanceof NIMError) {
        switch (error.detail.kind) {
          case 'modelUnavailable':
            return { kind: 'modelUnavailable', model: error.detail.model, detail: error.detail.detail };
          case 'emptyCompletion':
            return { kind: 'modelUnavailable', model: error.detail.model, detail: error.message };
          case 'unauthorized': return { kind: 'badKey' };
          case 'offline': return { kind: 'offline', why: error.detail.why };
          default: return { kind: 'serviceBusy', detail: error.message };
        }
      }
      return { kind: 'serviceBusy', detail: String(error) };
    }
  }

  /// The only call the dictation path is allowed to make.
  ///
  /// Never throws, never logs the key, and never takes longer than `deadline` —
  /// including the case where there is no key, where the breaker is open, and
  /// where the network hangs without ever answering. Returns null for every
  /// failure, because the caller already has a good deterministic answer and a
  /// null here means "use it", not "something went wrong".
  async cleanedTranscript(text: string, deadlineMs: number): Promise<string | null> {
    const trimmed = trim(text);
    if (trimmed.length === 0 || !this.key || this.isBreakerOpen) return null;
    try {
      const { AIOutputGuard } = await import('./outputGuard');
      const completion = await this.complete(this.config.systemPrompt, trimmed, null, deadlineMs);
      return AIOutputGuard.sanitise(completion, trimmed, this.vocabulary);
    } catch {
      return null;
    }
  }

  /// Used by the transform engine. The breaker check is what makes a transform
  /// on a train cost nothing.
  async completeTransform(system: string, user: string, deadlineMs: number): Promise<string | null> {
    if (!this.isConfigured || this.isBreakerOpen) return null;
    try {
      return await this.complete(system, user, null, deadlineMs);
    } catch {
      return null;
    }
  }

  private async performChat(
    system: string,
    user: string,
    model: string,
    key: string,
    timeoutMs: number,
  ): Promise<string> {
    const body = JSON.stringify({
      model,
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      temperature: this.config.temperature,
      top_p: this.config.topP,
      max_tokens: this.config.maxTokens,
      // Streaming would let the first token arrive sooner, but the caller needs
      // the whole cleaned sentence before it can insert anything — there is no
      // partial paste. Non-streaming keeps the parse trivial.
      stream: false,
    });

    let response: Response;
    try {
      response = await fetchWithDeadline(this.chatCompletionsURL, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${key}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body,
      }, timeoutMs);
    } catch (error) {
      if (error instanceof NIMError) throw error;
      throw new NIMError({ kind: 'offline', why: describeFetchFailure(error) });
    }

    const text = await response.text();
    switch (response.status) {
      case 200: return decodeCompletion(text, model, key);
      case 401:
      case 403: throw new NIMError({ kind: 'unauthorized' });
      case 404:
        throw new NIMError({ kind: 'modelUnavailable', model, detail: errorDetail(text, key) });
      case 429:
        throw new NIMError({ kind: 'rateLimited', retryAfter: retryAfterSeconds(response) });
      case 400:
      case 422:
        // Not transient: the same body will be rejected the same way.
        throw new NIMError({ kind: 'malformedResponse', what: errorDetail(text, key) });
      default:
        throw new NIMError({
          kind: 'serviceUnavailable',
          status: response.status,
          detail: errorDetail(text, key),
        });
    }
  }

  // MARK: - Circuit breaker

  /// Open means "do not even try". Costs nothing to check and saves the whole
  /// deadline on every dictation while the network is gone.
  get isBreakerOpen(): boolean {
    if (this.openedAt === null) return false;
    if (Date.now() - this.openedAt >= this.config.breakerCooldownMs) {
      // Half-open: let the next call through. If it fails the breaker re-trips
      // immediately, so the cost of being wrong is one request.
      this.openedAt = null;
      this.consecutiveFailures = 0;
      return false;
    }
    return true;
  }

  private noteFailure(): void {
    this.consecutiveFailures += 1;
    if (this.consecutiveFailures >= this.config.breakerThreshold && this.openedAt === null) {
      this.openedAt = Date.now();
    }
  }

  private noteSuccess(): void {
    this.consecutiveFailures = 0;
    this.openedAt = null;
  }

  /// For the settings pane's "try again now" button, and for tests.
  resetBreaker(): void {
    this.consecutiveFailures = 0;
    this.openedAt = null;
  }
}

// MARK: - Wire helpers

function decodeCompletion(body: string, model: string, key: string): string {
  let root: unknown;
  try {
    root = JSON.parse(body);
  } catch {
    throw new NIMError({ kind: 'malformedResponse', what: redact(body.slice(0, 200), key) });
  }
  const choices = (root as { choices?: unknown }).choices;
  if (!Array.isArray(choices) || choices.length === 0) {
    throw new NIMError({ kind: 'malformedResponse', what: redact(body.slice(0, 200), key) });
  }
  const message = (choices[0] as { message?: { content?: unknown } }).message;
  const content = typeof message?.content === 'string' ? trim(message.content) : '';
  if (content.length === 0) {
    // Measured: some reasoning models spend their entire token budget in
    // reasoning_content and return content: null every single time.
    throw new NIMError({ kind: 'emptyCompletion', model });
  }
  return content;
}

/// NVIDIA returns two different error envelopes and both show up in normal use:
/// `{"status":404,"title":…,"detail":…}` from the routing layer and
/// `{"error":{"message":…}}` from the model server.
export function errorDetail(body: string, key: string): string {
  let root: Record<string, unknown>;
  try {
    root = JSON.parse(body) as Record<string, unknown>;
  } catch {
    return redact(body.slice(0, 200), key);
  }
  const nested = root.error as { message?: unknown } | undefined;
  if (nested && typeof nested.message === 'string') return redact(nested.message.slice(0, 300), key);
  if (typeof root.detail === 'string') return redact(root.detail.slice(0, 300), key);
  if (typeof root.title === 'string') return redact(root.title.slice(0, 300), key);
  return redact(body.slice(0, 200), key);
}

/// Belt and braces. Nothing observed has ever echoed the key back, but this is
/// the one class of bug that cannot be fixed after it happens, so every string
/// derived from a response body goes through here before it can reach a log, an
/// alert or an error message.
export function redact(text: string, key: string): string {
  if (key.length === 0) return text;
  return text.split(key).join('[redacted]');
}

function retryAfterSeconds(response: Response): number | null {
  const raw = response.headers.get('Retry-After');
  if (!raw) return null;
  const value = Number.parseFloat(raw.trim());
  return Number.isFinite(value) ? value : null;
}

function describeFetchFailure(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  const lowered = message.toLowerCase();
  // Node's fetch reports almost everything as "fetch failed" with the real
  // reason on `cause`. The captive-portal signature is a TLS failure, which is
  // not the same as being offline and sends the user to a different fix.
  const cause = (error as { cause?: { code?: string; message?: string } }).cause;
  const code = cause?.code ?? '';
  switch (code) {
    case 'ENOTFOUND':
    case 'EAI_AGAIN':
      return 'DNS could not resolve integrate.api.nvidia.com';
    case 'ECONNREFUSED':
      return 'the connection was refused';
    case 'ECONNRESET':
      return 'the connection was lost';
    case 'ETIMEDOUT':
    case 'UND_ERR_CONNECT_TIMEOUT':
    case 'UND_ERR_HEADERS_TIMEOUT':
      return 'the request timed out';
    case 'ENETUNREACH':
    case 'EHOSTUNREACH':
      return 'no internet connection';
    case 'CERT_HAS_EXPIRED':
    case 'UNABLE_TO_VERIFY_LEAF_SIGNATURE':
    case 'DEPTH_ZERO_SELF_SIGNED_CERT':
    case 'SELF_SIGNED_CERT_IN_CHAIN':
      return 'TLS failed — this looks like a captive portal, not NVIDIA';
    default:
      break;
  }
  if (lowered.includes('abort')) return 'the request timed out';
  return cause?.message ?? message;
}

async function fetchWithDeadline(
  url: string,
  init: RequestInit,
  deadlineMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deadlineMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new NIMError({ kind: 'deadlineExceeded', milliseconds: deadlineMs });
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}

/// Races an operation against the clock.
///
/// The loser is abandoned rather than awaited: it holds a socket and a
/// rate-limit slot, and a caller held hostage by a network it cannot cancel is
/// the failure this exists to prevent. Measured on the macOS build, a task
/// group that awaited its children stalled a dictation for 59 seconds, which
/// presents as "it just didn't paste".
export async function withDeadline<T>(
  ms: number,
  operation: () => Promise<T>,
): Promise<T | null> {
  let settled = false;
  return new Promise<T | null>((resolve) => {
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolve(null);
    }, ms);
    operation().then(
      (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(null);
      },
    );
  });
}
