/*
 * C ABI for the SwitchHosts core (crates/swh-ffi).
 *
 * Threading
 *   - swh_invoke blocks until the command finishes. It can take a long time
 *     (applying to /etc/hosts waits for the OS authorization prompt), so call
 *     it from a background thread, never the main thread.
 *   - Events are delivered on arbitrary threads. The callback must not block
 *     and must hop to the UI thread itself.
 *   - Do not call swh_close while another thread is inside swh_invoke.
 *
 * Envelopes
 *   swh_invoke returns {"ok":true,"value":<json>} or {"ok":false,"error":"..."}.
 *
 * Ownership
 *   Strings returned by this library are freed with swh_free_string.
 */
#ifndef SWH_H
#define SWH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SwhHandle SwhHandle;

/*
 * Receives (user, event_name, payload_json). `user` is the pointer passed to
 * swh_open and must be safe to use from any thread. The strings are valid
 * only for the duration of the call.
 */
typedef void (*SwhEventCallback)(void *user, const char *event, const char *payload_json);

/*
 * Open the data directory at `root`, or the default ~/.SwitchHosts (honouring
 * the data-dir pointer) when `root` is NULL. Returns NULL on failure and sets
 * *error_out (if non-NULL) to a message to free with swh_free_string.
 */
SwhHandle *swh_open(const char *root, SwhEventCallback callback, void *user, char **error_out);

/* Free a handle. NULL is a no-op. */
void swh_close(SwhHandle *handle);

/*
 * Run `command` with `args_json`, a JSON array of positional arguments
 * (NULL means none). Returns a JSON envelope to free with swh_free_string.
 */
char *swh_invoke(const SwhHandle *handle, const char *command, const char *args_json);

/* Free a string returned by this library. NULL is a no-op. */
void swh_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif /* SWH_H */
