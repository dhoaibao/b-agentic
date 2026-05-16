# Security checklist

Use this checklist when `b-review` or another skill touches auth, untrusted input, sensitive data, file uploads, webhooks, or external integrations.

## Boundary checks

- Validate input at the first boundary that accepts it.
- Reject or normalize unexpected fields before business logic runs.
- Treat data from APIs, config, logs, and webhooks as untrusted until checked.

## Auth and authorization

- Confirm every protected path checks both authentication and authorization.
- Check owner/resource scoping, not just role presence.
- Verify new admin or elevated actions fail closed.

## Injection and encoding

- Confirm queries are parameterized.
- Confirm shell, template, and HTML sinks do not receive unsanitized input.
- Confirm output encoding is preserved across new rendering paths.

## Sensitive data

- Remove secrets, tokens, and internal details from logs and responses.
- Check that new responses do not expose internal fields by accident.
- Verify session and auth state stay in approved storage.

## Resource and abuse controls

- Check rate limits, retry bounds, upload size limits, pagination, or similar resource controls.
- Look for regex or parsing paths that can go pathological on hostile input.
- Check idempotency and replay safety where writes can be repeated.

## Dependency and config hygiene

- Question new dependencies on sensitive paths.
- Confirm security-relevant config changes fail closed when missing or mis-set.
- Check that error handling does not expose stack traces or implementation details.
