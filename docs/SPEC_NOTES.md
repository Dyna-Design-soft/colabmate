# Spec notes and open decisions

These are problems found in the SDLC Handover Document while implementing it.
Items marked **Decision needed** should be settled before the phase listed.

## Resolved in Phase 1–2

### 1. `google_sign_in` does not support Windows
The plugin has Android, iOS, macOS and Web implementations, but none for Windows.
**Done:** `AuthManager` uses a pluggable `AuthBackend`:
* Android: `google_sign_in`
* Windows: the standard "OAuth for installed apps" loopback flow with PKCE,
  which needs a **Desktop app** OAuth client

NFR-01 (no password handling) and NFR-02 (secure storage) still hold.

### 2. Dependency versions in §5 are outdated
The pinned versions date from about 2024. Current stable versions were used
instead. Notable API changes:

| Package | Spec | Used | Impact |
|---|---|---|---|
| google_sign_in | ^6.2.0 | ^7.2.0 | New `authenticate()` / `authorizationClient` API. `signIn()` returns `UserProfile` instead of `GoogleUser` |
| flutter_riverpod | ^2.5.0 | ^3.4.3 | Uses `AsyncNotifier` and `Provider` |
| flutter_local_notifications | ^17.0.0 | ^22.3.3 | **v17 had no Windows support** (added in v18) |
| flutter_secure_storage | ^9.0.0 | ^11.2.0 | — |
| drift | ^2.14.0 | ^2.35.3 (+ `drift_flutter`) | — |
| firebase_messaging | ^14.7.0 | ^17.0.1 | — |
| connectivity_plus | (Phase 8) | ^7.3.2 | Added now so all dependencies resolve together |

### 3. Drive scope and the 7-day refresh-token limit
FR-02/FR-06 need the full `drive` scope (`drive.file` only covers files the app
created). `drive` is a *restricted* scope. For a personal app, keep the consent
screen in **Testing** with yourself as a test user. While in Testing, Google
expires refresh tokens after **7 days**, so you will need to sign in again
about once a week. Publishing to Production would need Google's
restricted-scope verification. That is not worth it for a single-user app.

## Phase 3 implementation notes

* **Pending sync** is a `pending_sync` column on the cached notebook row
  (spec §4.2), so the offline→sync flow (D4–D6) already works in Phase 3.
  A separate `sync_queue_table` (Phase 8, step 39) is not needed for
  whole-file last-write-wins sync; revisit only if per-cell sync is wanted.
* Sync on reconnect (`connectivity_plus`, Phase 8 steps 37–38) is wired up now
  for the same reason.
* `listNotebooks()` returns `NotebookListing` (list + `fromCache` flag) so the
  UI can show the offline banner.
* Uploads keep the file's Drive MIME type
  (`application/vnd.google.colaboratory`), so Colab still opens edited files.
* An edit made while an upload is running stays pending (the upload only
  clears the flag if the cached content is unchanged).
* Signing out clears the notebook cache (after a warning if there are
  unsynced edits), so another account never sees cached notebooks.
* The Phase 3 editor is a plain text editor; Monaco arrives in Phase 6.

## Open: decide before Phase 4 (Runtime Manager)

### 4. Strategy A (bridge cell) cannot work as written. **Decision needed**
* The Colab kernel's Jupyter server listens on `localhost` **inside Google's VM**.
  A phone or PC has no network route to it, so `jupyter_client.dart` cannot
  call `/api/kernels` or open `/api/kernels/{id}/channels` there directly.
* `curl http://localhost:8888/api` returns only `{"version": "..."}`. It does
  not return a token.
* No Jupyter endpoint reports GPU% or RAM% (FR-03). Something on the VM has to
  collect them, for example with `nvidia-smi` or `psutil`.

Options that keep "no server *we* host" (NFR-07):
1. **Tunnel from the bridge cell** (recommended for v1): the cell starts a
   free tunnel such as `cloudflared` quick tunnel or ngrok to the Jupyter
   server. It also starts a tiny metrics endpoint and prints the public URL +
   a random token. The app pastes or scans that once. Cost is zero, but traffic
   goes through a third-party relay.
2. **Colab's internal "connect to runtime" API**, as used by Google's own
   VS Code extension, with the user's Google token. This avoids a third-party
   relay but is undocumented and can break (Risk 2).

### 5. Push notifications with no backend (FR-07..11, N3/N4). **Decision needed**
FCM needs a *sender*. The app cannot push to itself while it is closed, and
NFR-07 forbids a server. Options:
* **Sender = the bridge cell.** The notebook posts to FCM HTTP v1 when a cell
  finishes. This needs a Firebase service-account key inside the notebook,
  which is sensitive.
* **Sender = the bridge cell via ntfy.sh** or a similar free push relay, with
  no Firebase. This is simpler but uses a third-party service.
* **No push when closed.** The app keeps the WebSocket open (an Android
  foreground service) and shows *local* notifications. This passes N1–N3 but
  fails N4.

### 6. `webview_flutter` has no Windows implementation. **Decide before Phase 6/7**
Monaco on Windows needs `webview_windows` (WebView2) or `flutter_inappwebview`
(which supports both Android and Windows and could replace `webview_flutter`
entirely).

## Process notes
* The handover document suggests `main` and `dev` branches. This session's work
  is on `claude/new-session-dbs856`. Merge it into `dev`/`main` once the Auth
  gate passes.
* Android application ID: `com.dynaspede.colabmate`. The Android OAuth client
  must use this ID.
